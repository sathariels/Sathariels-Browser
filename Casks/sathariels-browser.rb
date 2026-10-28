cask "sathariels-browser" do
  version "0.7.0"
  sha256 "63098ba5cc28b58ce02f9e6a48fa8b0c0849a49925091421abf627fba9723c49"

  url "https://github.com/sathariels/Sathariels-Browser/releases/download/v#{version}/Sathariels.Browser-macos.zip"
  name "Sathariels Browser"
  desc "Small macOS browser"
  homepage "https://github.com/sathariels/Sathariels-Browser"

  # Sparkle stays dormant until a signing key is configured.
  auto_updates false
  depends_on macos: ">= :sonoma"

  app "Sathariels Browser.app"

  # Ad-hoc signature. Clearing quarantine lets the app open without a Developer ID.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Sathariels Browser.app"]
  end

  caveats do
    <<~EOS
      If Gatekeeper still blocks the first launch, run:

        xattr -dr com.apple.quarantine "#{appdir}/Sathariels Browser.app"

      Then right-click Sathariels Browser and choose Open.
      brew uninstall --zap keeps website data and the keychain for
      com.sathariels.browser, so saved logins stay on this Mac.
    EOS
  end

  # Do not list the app container. Cookies, local storage, and the
  # session live in ~/Library/Containers/com.sathariels.browser.
  zap trash: [
    "~/Library/Caches/com.sathariels.browser",
    "~/Library/Preferences/com.sathariels.browser.plist",
    "~/Library/Saved Application State/com.sathariels.browser.savedState",
  ]
end
