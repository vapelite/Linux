function kvm
    set input $argv[1]
    
    if test -z "$input"
        echo "Usage: kvm <repo_url_or_owner/repo>"
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
    
    if test -d $repo_name
        echo "Duplicate local folder detected: '$repo_name' already exists."
        echo "Removing old folder and downloading a fresh copy to get the latest updates..."
        rm -rf $repo_name
    end
    
    echo "Cloning fresh copy of $repo_name..."
    git clone $repo_url
    cd $repo_name
    
    # Parse host and repository path for APIs
    set url_parts (string match -r 'https?://([^/]+)/(.*)' $repo_url)
    set host $url_parts[2]
    set repo_path (string replace -r '\.git$' '' $url_parts[3])
    
    # Handle GitHub repository creation / sync
    if string match -q "*github.com*" $repo_url
        echo "Checking GitHub repository status..."
        if not gh repo view "$target_owner/$repo_name" > /dev/null 2>&1
            echo "Creating new private repository on GitHub..."
            gh repo create "$target_owner/$repo_name" --private
        end
        git remote set-url origin https://github.com/$target_owner/$repo_name.git
        git push -u origin HEAD
    else
        echo "Non-GitHub git repository detected. Creating private mirror on GitHub..."
        if not gh repo view "$target_owner/$repo_name" > /dev/null 2>&1
            gh repo create "$target_owner/$repo_name" --private
        end
        git remote set-url origin https://github.com/$target_owner/$repo_name.git
        git push -u origin --all
        git push -u origin --tags
    end
    
    # Fetch and upload releases (Supports GitHub & Gitea/Forgejo APIs)
    if string match -q "*github.com*" $repo_url
        echo "Fetching up to 6 latest releases from upstream ($repo_path)..."
        set release_tags (gh release list -R "$repo_path" --limit 6 --json tagName --jq '.[].tagName')
        
        if test -n "$release_tags"
            echo "Found releases. Uploading release assets one by one..."
            for tag in $release_tags
                echo "Processing release: $tag"
                
                if not gh release view "$tag" -R "$target_owner/$repo_name" > /dev/null 2>&1
                    gh release create "$tag" -R "$target_owner/$repo_name" --title "$tag" --notes "Mirrored release from $repo_path"
                end
                
                set asset_info (gh release view "$tag" -R "$repo_path" --json assets --jq '.assets[] | "\(.name)|\(.url)"')
                
                for item in $asset_info
                    set parts (string split "|" $item)
                    set asset_name $parts[1]
                    set asset_url $parts[2]
                    
                    if gh release view "$tag" -R "$target_owner/$repo_name" --json assets --jq '.assets[].name' | grep -q "$asset_name"
                        echo "  -> Asset '$asset_name' already exists in release $tag. Skipping."
                        continue
                    end
                    
                    echo "  -> Downloading asset: $asset_name"
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
        # Gitea / Forgejo API release sync for custom instances (like git.imtheo.lol)
        echo "Fetching up to 6 latest releases via Gitea/Forgejo API on $host..."
        set api_url "https://$host/api/v1/repos/$repo_path/releases"
        set releases_json (curl -s "$api_url")
        
        if test -n "$releases_json"
            set tags (echo "$releases_json" | jq -r '.[0:6] | .[].tag_name' 2>/dev/null)
            
            if test -n "$tags" -a "$tags" != "null"
                echo "Found releases on custom host. Creating releases and uploading assets..."
                for tag in $tags
                    echo "Processing release: $tag"
                    
                    if not gh release view "$tag" -R "$target_owner/$repo_name" > /dev/null 2>&1
                        gh release create "$tag" -R "$target_owner/$repo_name" --title "$tag" --notes "Mirrored release from $repo_url"
                    end
                    
                    set assets (echo "$releases_json" | jq -r --arg t "$tag" '.[] | select(.tag_name == $t) | .assets[]? | "\(.name)|\(.browser_download_url)"' 2>/dev/null)
                    
                    for asset_line in $assets
                        set parts (string split "|" $asset_line)
                        set asset_name $parts[1]
                        set asset_url $parts[2]
                        
                        if gh release view "$tag" -R "$target_owner/$repo_name" --json assets --jq '.assets[].name' | grep -q "$asset_name"
                            echo "  -> Asset '$asset_name' already exists in release $tag. Skipping."
                            continue
                        end
                        
                        echo "  -> Downloading asset: $asset_name"
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
    
    echo "Done! Synced and uploaded source + releases to https://github.com/$target_owner/$repo_name"
end
