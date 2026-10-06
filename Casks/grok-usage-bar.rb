# Template for https://github.com/exbtpy/homebrew-tap
# Names mirror macos/identity.env. Copy this file into the tap.
# The release workflow rewrites `version` and `sha256` when HOMEBREW_TAP_TOKEN is set.
# `sha256` below is a placeholder. `brew install` will reject it until a release fills it in.
cask "grok-usage-bar" do
  version "1.0.0"
  sha256 "REPLACE_ON_RELEASE"

  url "https://github.com/exbtpy/grok-usage-bar/releases/download/v#{version}/GrokUsageBar.dmg"
  name "Grok Usage Bar"
  desc "Menu bar meters for Grok Bot and the SuperGrok weekly pool"
  homepage "https://github.com/exbtpy/grok-usage-bar"

  depends_on macos: ">= :sonoma"

  app "GrokUsageBar.app"

  zap trash: [
    "~/.config/grok-usage-bar",
    "~/Library/Preferences/com.exbtpy.GrokUsageBar.plist",
  ]
end
