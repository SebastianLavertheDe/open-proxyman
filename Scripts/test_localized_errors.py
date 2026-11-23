#!/usr/bin/env python3
"""Compile production error rendering and helper wire errors with real bilingual resources.

The shared error struct is extracted unchanged from the macOS module because the
rest of SystemProxySettings imports SystemConfiguration. No proxy operation runs.
"""
import argparse,json,os,plistlib,shutil,subprocess,tempfile,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
MAIN=r'''
import Foundation
import ProxyMirrorSystemProxy
@main struct Checks {
    static func main() throws {
        var count=0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message); count += 1
        }
        let language = ProcessInfo.processInfo.environment["PM_SETTINGS_LANGUAGE"]!
        let issue=OperationIssue.certificateFormatsTheCertificateDoesNotMatchThePrivateKey
        let error=SystemProxyOperationError(issue)
        check(issue.code == "certificate_formats_the_certificate_does_not_match_the_private_key", "stable issue code")
        check(error.localizedDescription == "The certificate does not match the private key.", "diagnostic language is stable")
        let presentation=LocalizedErrorPresentation.message(for:error)
        check(presentation == (language == "en" ? "The certificate does not match the private key." : "证书与私钥不匹配。"), "localized presentation")
        let parameterIssue=OperationIssue.networkAccessPolicyInvalidIpAddressOrCidr("bad-input")
        check(parameterIssue.diagnostic == "Invalid IP address or CIDR: bad-input", "typed diagnostic parameters")
        check(parameterIssue.localizedPresentation.contains("bad-input"), "presentation preserves original parameters")
        let response=ReleaseUpdate.Failure.http(503)
        check(response.localizedDescription == "The update check failed (HTTP 503).", "release errors stay diagnostic")
        check(LocalizedErrorPresentation.message(for:response) == (language == "en" ? "The update check failed (HTTP 503)." : "更新检查失败（HTTP 503）。"), "release presentation")
        do { _ = try NetworkAccessPolicy(ranges:["not-an-ip"]); preconditionFailure("invalid range") }
        catch {
            check(error is NetworkAccessPolicy.ValidationError, "production validation error type")
            check(error.localizedDescription.contains("not-an-ip"), "diagnostic range")
            check(LocalizedErrorPresentation.message(for:error).contains("not-an-ip"), "localized range")
        }
        do { _ = try DeviceAutomation.parseDevices("bad"); preconditionFailure("invalid device list") }
        catch { check(error is DeviceAutomation.AutomationError, "production device validation") }
        let guide=CertificatePlatformGuides.guide(for:"Java", certificatePath:"/tmp/a'$(echo unsafe).pem",port:9090)
        check(guide.steps.count == 2, "complete guide")
        check(guide.steps[0].contains(language == "en" ? "JAVA_HOME points" : "JAVA_HOME 指向"), "guide language")
        check(guide.commands.contains("-Dhttps.proxyPort=9090"), "guide command port")
        check(guide.commands.contains("'\\''"), "guide shell quoting")
        let first=SystemProxyError(.invalidPort)
        let round=SystemProxyError.fromWire(first.wireValue)
        check(round.code == .invalidPort && round.arguments.isEmpty, "structured helper roundtrip")
        check(round.localizedDescription == "The system proxy port is invalid.", "helper has stable English diagnosis")
        check(LocalizedErrorPresentation.message(for:round) == (language == "en" ? "The system proxy port is invalid." : "系统代理端口无效。"), "helper presentation uses its stable code")
        check(SystemProxyBypassList.validationFailure(["bad host"])?.code == .bypassInvalid, "structured bypass validation")
        check(SystemProxyBypassList.validationError(["bad host"])?.hasPrefix("Invalid bypass entry:") == true, "bypass machine diagnostic")
        let bypass=SystemProxyError(.bypassInvalid,arguments:["bad host"])
        let decoded=SystemProxyError.fromWire(bypass.wireValue)
        check(decoded.code == .bypassInvalid && decoded.arguments == ["bad host"], "helper typed parameters")
        check(SystemProxyError.fromWire("legacy technical message").code == nil, "legacy helper text fallback")
        for code in SystemProxyError.Code.allCases {
            let arguments = code == .bypassInvalid ? ["bad host"] : []
            let original = SystemProxyError(code, arguments: arguments)
            let recovered = SystemProxyError.fromWire(original.wireValue)
            check(recovered.code == code && recovered.arguments == arguments, "all helper codes roundtrip")
            let text = LocalizedErrorPresentation.message(for: recovered)
            check(!text.isEmpty && !text.contains("pm-error-v1:"), "helper codes never display transport JSON")
            check(language == "en" ? text == recovered.localizedDescription : text.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) }, "all helper codes render in selected language")
        }
        let malformed="pm-error-v1:{\"version\":1,\"domain\":\"ProxyMirror.SystemProxy\",\"code\":\"bypassInvalid\",\"arguments\":[]}"
        check(SystemProxyError.fromWire(malformed).code == nil, "reject malformed parameter count")
        check(SystemProxyError.fromWire("pm-error-v1:"+String(repeating:"x",count:66000)).code == nil, "bound transport data")
        print("PASS: \(count) production diagnostic/presentation/guide/transport checks [\(language)]")
    }
}
'''
def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--swiftc',default='swiftc');args=parser.parse_args();swiftc=shutil.which(args.swiftc) or args.swiftc
    with tempfile.TemporaryDirectory(prefix='pm-localized-errors-') as directory:
        folder=Path(directory); entry=folder/'Checks.swift';entry.write_text(MAIN)
        shared=(ROOT/'Sources/ProxyMirrorSystemProxy/SystemProxySettings.swift').read_text();start=shared.index('package struct SystemProxyError:');end=shared.index('\npackage final class SystemProxySettings',start)
        transport=folder/'SystemProxyError.swift';transport.write_text('import Foundation\n'+shared[start:end])
        library=folder/('libProxyMirrorSystemProxy.dylib' if sys.platform=='darwin' else 'libProxyMirrorSystemProxy.so')
        subprocess.run([swiftc,'-swift-version','5','-package-name','ProxyMirror','-emit-module','-emit-library','-module-name','ProxyMirrorSystemProxy','-emit-module-path',str(folder/'ProxyMirrorSystemProxy.swiftmodule'),str(transport),str(ROOT/'Sources/ProxyMirrorSystemProxy/SystemProxyBypassList.swift'),'-o',str(library)],check=True,timeout=120)
        source=['Localization/AppLanguage.swift','Localization/LocalizationContext.swift','Localization/LocalizationResources.swift','UI/PresentationLocalization.swift','System/LocalizedErrorPresentation.swift','System/GeneratedOperationIssues.swift','System/ReleaseUpdate.swift','System/NetworkAccessPolicy.swift','System/DeviceAutomation.swift','System/CertificatePlatformGuides.swift','Localization/Generated/Strings.swift','Localization/Generated/EnglishFallbacks.swift']
        paths=[]
        for relative in source:
            original=ROOT/'Sources/ProxyMirrorCore'/relative
            copied=folder/'production'/relative
            copied.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(original,copied)
            paths.append(str(copied))
        binary=folder/'checks'
        subprocess.run([swiftc,'-swift-version','5','-package-name','ProxyMirror','-module-cache-path',str(folder/'modules'),'-I',str(folder),'-L',str(folder),'-lProxyMirrorSystemProxy','-Xlinker','-rpath','-Xlinker',str(folder),*paths,str(entry),'-o',str(binary)],check=True,timeout=180)
        bundle=folder/'Resources.bundle';bundle.mkdir();(bundle/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'test.ProxyMirror.Errors','CFBundleDevelopmentRegion':'en','CFBundleLocalizations':['en','zh-Hans']}))
        for language in ['en','zh-Hans']:
            target=bundle/f'{language}.lproj';target.mkdir()
            for table in ['Errors','Guides']:shutil.copy2(ROOT/f'Sources/ProxyMirrorCore/Resources/{language}.lproj/{table}.strings',target/f'{table}.strings')
        for language in ['en','zh-Hans']:
            env=dict(os.environ,PM_SETTINGS_LANGUAGE=language,PM_LOCALIZATION_RESOURCE_DIR=str(bundle))
            subprocess.run([str(binary)],env=env,check=True,timeout=20)
if __name__=='__main__':main()
