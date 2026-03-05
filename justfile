id := "st.lynx.plugins.opendeck-akp03-zig.sdPlugin"

release: bump package tag

package: build-linux package-zig

package-build: package

bump next=`git cliff --bumped-version | tr -d "v"`:
    git diff --cached --exit-code

    echo "We will bump version to {{next}}, press any key"
    read ans

    sed -i 's/"Version": ".*"/"Version": "{{next}}"/g' manifest.json

tag next=`git cliff --bumped-version`:
    echo "Generating changelog"
    git cliff -o CHANGELOG.md --tag {{next}}

    echo "We will now commit the changes, please review before pressing any key"
    read ans

    git add .
    git commit -m "chore(release): {{next}}"
    git tag "{{next}}"

build-linux:
    zig build -Doptimize=ReleaseFast -p target/plugin-linux

package-zig:
    zig build package -Doptimize=ReleaseFast

clean:
    sudo rm -rf target/

collect:
    rm -rf build
    mkdir -p build/{{id}}
    cp -r assets build/{{id}}
    cp manifest.json build/{{id}}
    cp target/plugin-linux/bin/opendeck-akp03-zig build/{{id}}/opendeck-akp03-zig-linux

[working-directory: "build"]
zip:
    rm -f ../opendeck-akp03-zig.plugin.zip
    zip -r ../opendeck-akp03-zig.plugin.zip {{id}}/
