.PHONY: build app zip dmg release-artifacts verify-release install clean

build:
	cd macos && swift build -c release

app:
	bash macos/scripts/build.sh

zip:
	bash macos/scripts/build.sh --zip
	bash macos/scripts/verify-release.sh macos/GrokUsageBar.zip

dmg:
	bash macos/scripts/build.sh --dmg
	bash macos/scripts/verify-release.sh macos/GrokUsageBar.dmg

release-artifacts:
	bash macos/scripts/build.sh --zip --dmg
	bash macos/scripts/verify-release.sh macos/GrokUsageBar.zip
	bash macos/scripts/verify-release.sh macos/GrokUsageBar.dmg

verify-release:
	bash macos/scripts/verify-release.sh macos/GrokUsageBar.zip
	if [ -f macos/GrokUsageBar.dmg ]; then bash macos/scripts/verify-release.sh macos/GrokUsageBar.dmg; fi

install: app
	rm -rf /Applications/GrokUsageBar.app
	cp -R macos/GrokUsageBar.app /Applications/

clean:
	cd macos && swift package clean
	rm -rf macos/GrokUsageBar.app macos/GrokUsageBar.zip macos/GrokUsageBar.dmg
