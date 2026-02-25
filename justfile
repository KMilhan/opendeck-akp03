id := "st.lynx.plugins.opendeck-akp03.sdPlugin"

release: bump package tag

package: build-linux build-mac build-win package-zig

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

build-mac:
    zig build -Doptimize=ReleaseFast -Dtarget=x86_64-macos -p target/plugin-mac-x64
    zig build -Doptimize=ReleaseFast -Dtarget=aarch64-macos -p target/plugin-mac-arm64
    mkdir -p target/plugin-mac/bin
    lipo -create -output target/plugin-mac/bin/opendeck-akp03 target/plugin-mac-x64/bin/opendeck-akp03 target/plugin-mac-arm64/bin/opendeck-akp03

build-win:
    zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows-gnu -p target/plugin-win

package-zig:
    zig build package -Dpackage-host-only -Doptimize=ReleaseFast

clean:
    sudo rm -rf target/

collect:
    rm -rf build
    mkdir -p build/{{id}}
    cp -r assets build/{{id}}
    cp manifest.json build/{{id}}
    cp target/plugin-linux/bin/opendeck-akp03 build/{{id}}/opendeck-akp03-linux
    cp target/plugin-mac/bin/opendeck-akp03 build/{{id}}/opendeck-akp03-mac
    cp target/plugin-win/bin/opendeck-akp03.exe build/{{id}}/opendeck-akp03-win.exe

[working-directory: "build"]
zip:
    zip -r opendeck-akp03.plugin.zip {{id}}/
