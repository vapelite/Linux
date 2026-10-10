function kvmupd
    set input $argv[1]
    
    if test -z "$input"
        echo "Usage: kvmupd <repo_url_or_owner/repo>"
        return 1
    end
    
    if string match -r '^https?://' $input > /dev/null
        set clean_url (string replace -r '#.*$' '' $input)
        set clean_url (string replace -r '/releases/?$' '' $clean_url)
        set clean_url (string replace -r '/$' '' $clean_url)
        
        set repo_url $clean_url
        set repo_name (basename $repo_url .git)
    else
        set repo_url "https://github.com/$input.git"
        set repo_name (basename $input)
    end
    
    set target_owner "vapelite"
    
    cd ~
    
    # Check if folder exists; if not, fall back to cloning
    if not test -d $repo_name
        echo "Local folder '$repo_name' not found. Performing fresh clone..."
        git clone $repo_url
        cd $repo_name
        
        # Set up upstream and origin remotes
        git remote rename origin upstream
        if not gh repo view "$target_owner/$repo_name" > /dev/null 2>&1
            gh repo create "$target_owner/$repo_name" --private
        end
        git remote add origin https://github.com/$target_owner/$repo_name.git
        git push -u origin --all
        git push -u origin --tags
    else
        echo "Found existing local folder for '$repo_name'. Updating incrementally..."
        cd $repo_name
        
        # Ensure 'upstream' points to the original repo source, and 'origin' points to vapelite
        if not git remote | grep -q "upstream"
            git remote rename origin upstream 2>/dev/null; or git remote add upstream $repo_url
        end
        git remote set-url upstream $repo_url
        
        if not git remote | grep -q "origin"
            git remote add origin https://github.com/$target_owner/$repo_name.git
        else
            git remote set-url origin https://github.com/$target_owner/$repo_name.git
        end
        
        echo "Fetching latest changes from upstream..."
        git fetch upstream
        git pull upstream HEAD
        git fetch upstream --tags
        
        echo "Pushing updates to vapelite mirror..."
        git push origin --all
        git push origin --tags
    end
    
    # Parse host and repo path for release synchronization
    set url_parts (string match -r 'https?://([^/]+)/(.*)' $repo_url)
    set host $url_parts[2]
    set repo_path (string replace -r '\.git$' '' $url_parts[3])
    
    # Sync releases efficiently (only checking/downloading missing ones)
    if string match -q "*github.com*" $repo_url
        echo "Checking latest releases from GitHub..."
        set release_tags (gh release list -R "$repo_path" --limit 6 --json tagName --jq '.[].tagName')
        
        if test -n "$release_tags"
            for tag in $release_tags
                if gh release view "$tag" -R "$target_owner/$repo_name" > /dev/null 2>&1
                    echo "Release $tag already exists on mirror. Skipping release creation."
                else
                    echo "Found new release: $tag. Creating on mirror..."
                    gh release create "$tag" -R "$target_owner/$repo_name" --title "$tag" --notes "Mirrored release from $repo_path"
                end
                
                set asset_info (gh release view "$tag" -R "$repo_path" --json assets --jq '.assets[] | "\(.name)|\(.url)"')
                
                for item in $asset_info
                    set parts (string split "|" $item)
                    set asset_name $parts[1]
                    
                    if gh release view "$tag" -R "$target_owner/$repo_name" --json assets --jq '.assets[].name' | grep -q "$asset_name"
                        echo "  -> Asset '$asset_name' already uploaded. Skipping."
                        continue
                    end
                    
                    echo "  -> Downloading new asset: $asset_name"
                    gh release download "$tag" -R "$repo_path" -p "$asset_name"
                    
                    if test -f "$asset_name"
                        echo "  -> Uploading asset '$asset_name' to vapelite/$repo_name..."
                        gh release upload "$tag" "$asset_name" -R "$target_owner/$repo_name" --clobber
                        rm -f "$asset_name"
                    end
                end
            end
        else
            echo "No releases found for this repository."
        end
    else
        # Gitea / Forgejo API incremental release sync
        echo "Checking releases via Gitea/Forgejo API on $host..."
        set api_url "https://$host/api/v1/repos/$repo_path/releases"
        set releases_json (curl -s "$api_url")
        
        if test -n "$releases_json"
            set tags (echo "$releases_json" | jq -r '.[0:6] | .[].tag_name' 2>/dev/null)
            
            if test -n "$tags" -a "$tags" != "null"
                for tag in $tags
                    if gh release view "$tag" -R "$target_owner/$repo_name" > /dev/null 2>&1
                        echo "Release $tag already exists on mirror. Checking assets..."
                    else
                        echo "Found new release: $tag. Creating on mirror..."
                        gh release create "$tag" -R "$target_owner/$repo_name" --title "$tag" --notes "Mirrored release from $repo_url"
                    end
                    
                    set assets (echo "$releases_json" | jq -r --arg t "$tag" '.[] | select(.tag_name == $t) | .assets[]? | "\(.name)|\(.browser_download_url)"' 2>/dev/null)
                    
                    for asset_line in $assets
                        set parts (string split "|" $asset_line)
                        set asset_name $parts[1]
                        set asset_url $parts[2]
                        
                        if gh release view "$tag" -R "$target_owner/$repo_name" --json assets --jq '.assets[].name' | grep -q "$asset_name"
                            echo "  -> Asset '$asset_name' already uploaded. Skipping."
                            continue
                        end
                        
                        echo "  -> Downloading new asset: $asset_name"
                        curl -sL -o "$asset_name" "$asset_url"
                        
                        if test -f "$asset_name"
                            echo "  -> Uploading asset '$asset_name' to vapelite/$repo_name..."
                            gh release upload "$tag" "$asset_name" -R "$target_owner/$repo_name" --clobber
                            rm -f "$asset_name"
                        end
                    end
                end
            else
                echo "No releases found on this custom repository."
            end
        else
            echo "Could not reach releases API for this host."
        end
    end
    
    echo "Done! Incremental update complete for https://github.com/$target_owner/$repo_name"
end
