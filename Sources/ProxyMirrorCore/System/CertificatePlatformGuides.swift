import Foundation

enum CertificatePlatformGuides {
    struct Link: Identifiable { let title: String; let url: URL; var id: String { url.absoluteString } }
    struct Guide { let steps: [String]; let commands: String; let links: [Link] }

    static let frameworks = ["Java", "NextJS", "Docker", "React Native", "Flutter", "Python", "Ruby", "NodeJS", "Electron", "HTTP Clients", "VPN"]
    static let simulatorPlatforms = ["watchOS", "tvOS", "visionOS", "Xcode Preview (SwiftUI)"]

    static func guide(for platform: String, certificatePath: String, port: Int) -> Guide {
        let proxy = "http://127.0.0.1:\(port)"
        let environment = "PM_CA=\(shellQuote(certificatePath))\nPM_PROXY=\(shellQuote(proxy))\n"
        func link(_ title: String, _ url: String) -> Link { Link(title: title, url: URL(string: url)!) }
        switch platform {
        case "iOS":
            return Guide(steps: [
                Strings.Guides.certificatePlatformGuidesInTheDeviceWiFiSettingsSetThe,
                Strings.Guides.certificatePlatformGuidesExportTheCaCertificateAndSendItTo,
                Strings.Guides.certificatePlatformGuidesSendARequestFromYourOwnTestApp
            ], commands: "", links: [link(Strings.Guides.certificatePlatformGuidesAppleInstallACertificateManuallyAndEnableTrust, "https://support.apple.com/en-us/102390")])
        case "Android":
            return Guide(steps: [
                Strings.Guides.certificatePlatformGuidesPointTheDeviceWiFiProxyToThe,
                Strings.Guides.certificatePlatformGuidesInstallTheExportedCaFromSecurityEncryptionCredentials,
                Strings.Guides.certificatePlatformGuidesYourOwnDebugAppCanTrustUserCertificates,
                Strings.Guides.certificatePlatformGuidesProxymirrorDoesNotProvideAnAndroidVpnCompanion
            ], commands: "<network-security-config>\n  <debug-overrides>\n    <trust-anchors><certificates src=\"user\" /></trust-anchors>\n  </debug-overrides>\n</network-security-config>", links: [link("Android：Network Security Config", "https://developer.android.com/privacy-and-security/security-config")])
        case "watchOS", "tvOS", "visionOS", "Xcode Preview (SwiftUI)":
            let preview = platform == "Xcode Preview (SwiftUI)"
            return Guide(steps: [
                Strings.Guides.certificatePlatformGuidesInstallTheCorrespondingSimulatorRuntimeInXcodeStart,
                Strings.Guides.certificatePlatformGuidesRunAddRootCertBelowThenRouteRequests,
                preview ? Strings.Guides.certificatePlatformGuidesForIosVisionosPreviewTrustTheCaIn : Strings.Guides.certificatePlatformGuidesWatchosAlsoInvolvesThePairedIphoneAndIts
            ], commands: environment + "xcrun simctl list devices available\nxcrun simctl help keychain\nPM_SIMULATOR_UDID='REPLACE_WITH_TARGET_UDID'\nxcrun simctl keychain \"$PM_SIMULATOR_UDID\" add-root-cert \"$PM_CA\"",
                links: [link("Apple：Simulator", "https://developer.apple.com/documentation/xcode/running-your-app-in-simulator-or-on-a-device")])
        case "Java":
            return Guide(steps: [
                Strings.Guides.certificatePlatformGuidesCheckThatJavaHomePointsToTheJdk,
                Strings.Guides.certificatePlatformGuidesAtRuntimeConfigureTheHttpHttpsProxyAnd
            ], commands: environment + "cp \"$JAVA_HOME/lib/security/cacerts\" ./proxymirror-java-cacerts\nkeytool -importcert -alias proxymirror-ca -file \"$PM_CA\" -keystore ./proxymirror-java-cacerts\njava -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=\(port) -Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=\(port) -Djavax.net.ssl.trustStore=\"$PWD/proxymirror-java-cacerts\" -jar app.jar",
                links: [link("Oracle：keytool", "https://docs.oracle.com/en/java/javase/25/docs/specs/man/keytool.html")])
        case "NodeJS", "NextJS":
            return Guide(steps: [
                Strings.Guides.certificatePlatformGuidesSetNodeExtraCaCertsBeforeStartingNode,
                platform == "NextJS" ? Strings.Guides.certificatePlatformGuidesTheCommandBelowTargetsTheNextJsNode : Strings.Guides.certificatePlatformGuidesVerifyHttpAndHttpsAgainstATestDomain
            ], commands: environment + "HTTP_PROXY=\"$PM_PROXY\" HTTPS_PROXY=\"$PM_PROXY\" NODE_USE_ENV_PROXY=1 NODE_EXTRA_CA_CERTS=\"$PM_CA\" " + (platform == "NextJS" ? "npm run dev" : "node app.js"),
                links: [link(Strings.Guides.certificatePlatformGuidesNodeJsProxyEnvironmentAndExtraCas, "https://nodejs.org/api/cli.html#node_use_env_proxy1"), link("Undici：ProxyAgent", "https://undici.nodejs.org/#/docs/api/ProxyAgent")])
        case "Python":
            return Guide(steps: [
                Strings.Guides.certificatePlatformGuidesRequestsUsesHttpProxyHttpsProxyAndRequests,
                Strings.Guides.certificatePlatformGuidesStandardLibrariesSuchAsUrllibSslUseTheir
            ], commands: environment + "HTTP_PROXY=\"$PM_PROXY\" HTTPS_PROXY=\"$PM_PROXY\" REQUESTS_CA_BUNDLE=\"$PM_CA\" python app.py",
                links: [link(Strings.Guides.certificatePlatformGuidesRequestsSslAndProxies, "https://requests.readthedocs.io/en/latest/user/advanced/#ssl-cert-verification")])
        case "Ruby":
            return Guide(steps: [
                Strings.Guides.certificatePlatformGuidesForRubyHttpLibrariesSupportingProxyEnvironmentVariables,
                Strings.Guides.certificatePlatformGuidesNetHttpCanExplicitlyUseNetHttpProxy
            ], commands: environment + "http_proxy=\"$PM_PROXY\" https_proxy=\"$PM_PROXY\" SSL_CERT_FILE=\"$PM_CA\" ruby app.rb",
                links: [link("Ruby：Net::HTTP", "https://docs.ruby-lang.org/en/master/Net/HTTP.html")])
        case "Docker":
            return Guide(steps: [
                Strings.Guides.certificatePlatformGuidesContainersHaveTheirOwnTruststoresAndNetworkNamespaces,
                Strings.Guides.certificatePlatformGuidesDockerDesktopNormallyReachesTheMacThroughHost
            ], commands: "# Place the exported CA in the Docker build context\nCOPY proxymirror-ca.pem /usr/local/share/ca-certificates/proxymirror-ca.crt\nRUN update-ca-certificates\nENV HTTP_PROXY=http://host.docker.internal:\(port)\nENV HTTPS_PROXY=http://host.docker.internal:\(port)",
                links: [link(Strings.Guides.certificatePlatformGuidesDockerContainerCaCertificates, "https://docs.docker.com/engine/network/ca-certs/")])
        case "React Native":
            return Guide(steps: [
                Strings.Guides.certificatePlatformGuidesForIosDebugBuildsInstallAndTrustThe,
                Strings.Guides.certificatePlatformGuidesAndroidEmulatorUses10022Physical(Int(port)),
                Strings.Guides.certificatePlatformGuidesReactNativeFetchUsesThePlatformNativeNetwork
            ], commands: "<network-security-config>\n  <debug-overrides>\n    <trust-anchors><certificates src=\"user\" /></trust-anchors>\n  </debug-overrides>\n</network-security-config>",
                links: [link("React Native：Networking", "https://reactnative.dev/docs/network"), link("Android：Debug CA", "https://developer.android.com/privacy-and-security/security-config#debug-overrides")])
        case "Flutter":
            return Guide(steps: [
                Strings.Guides.certificatePlatformGuidesDartHttpclientCanSetFindproxyExplicitlyAndAdd,
                Strings.Guides.certificatePlatformGuidesThe10022AddressBelowTargets
            ], commands: "import 'dart:io';\nimport 'package:flutter/services.dart';\n\nfinal ca = await rootBundle.load('assets/proxymirror-ca.pem');\nfinal context = SecurityContext(withTrustedRoots: true);\ncontext.setTrustedCertificatesBytes(\n  ca.buffer.asUint8List(ca.offsetInBytes, ca.lengthInBytes),\n);\nfinal client = HttpClient(context: context)\n  ..findProxy = (_) => 'PROXY 10.0.2.2:\(port)';",
                links: [link("Dart：HttpClient.findProxy", "https://api.dart.dev/dart-io/HttpClient/findProxy.html"), link("Dart：SecurityContext", "https://api.dart.dev/dart-io/SecurityContext-class.html")])
        case "Electron":
            return Guide(steps: [
                Strings.Guides.certificatePlatformGuidesAfterAppReadyAndBeforeCreatingABrowserwindow,
                Strings.Guides.certificatePlatformGuidesConfigureTheNodeProxyAndCaSeparatelyFor
            ], commands: "const { app, session, BrowserWindow } = require('electron');\napp.whenReady().then(async () => {\n  await session.defaultSession.setProxy({\n    proxyRules: 'http=127.0.0.1:\(port);https=127.0.0.1:\(port)',\n  });\n  const window = new BrowserWindow();\n  await window.loadURL('https://example.com');\n});",
                links: [link("Electron：session.setProxy", "https://www.electronjs.org/docs/latest/api/session#sessetproxyconfig")])
        case "HTTP Clients":
            return Guide(steps: [
                Strings.Guides.certificatePlatformGuidesInPostmanInsomniaPawProxySettingsUseHttp(Int(port)),
                Strings.Guides.certificatePlatformGuidesAddTheExportedProxymirrorCaInTheClient,
                Strings.Guides.certificatePlatformGuidesSendATestRequestAndVerifyDecryptedTraffic
            ], commands: environment + "curl --proxy \"$PM_PROXY\" --cacert \"$PM_CA\" https://example.com/",
                links: [link(Strings.Guides.certificatePlatformGuidesPostmanProxyConfiguration, "https://learning.postman.com/docs/getting-started/installation/proxy/")])
        case "VPN":
            return Guide(steps: [
                Strings.Guides.certificatePlatformGuidesVpnRoutesTheSystemHttpProxyAndProxymirror,
                Strings.Guides.certificatePlatformGuidesIfAnAppIgnoresTheSystemProxyUse,
                Strings.Guides.certificatePlatformGuidesConfiguringACaDoesNotAutomaticallyResolveCertificate
            ], commands: environment + "curl --proxy \"$PM_PROXY\" --cacert \"$PM_CA\" https://example.com/",
                links: [link("Apple：Network Extension", "https://developer.apple.com/documentation/networkextension")])
        case "Firefox":
            return Guide(steps: [
                Strings.Guides.certificatePlatformGuidesFirefoxSettingsNetworkSettingsManuallyConfigureProxy127(Int(port)),
                Strings.Guides.certificatePlatformGuidesPrivacySecurityCertificatesViewCertificatesAuthoritiesImportThe
            ], commands: "", links: [link(Strings.Guides.certificatePlatformGuidesMozillaFirefoxCertificates, "https://support.mozilla.org/en-US/kb/setting-certificate-authorities-firefox")])
        default: return Guide(steps: [Strings.Guides.certificatePlatformGuidesChooseAPlatformInTheCertificateMenuTo], commands: "", links: [])
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
