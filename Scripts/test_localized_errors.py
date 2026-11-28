#!/usr/bin/env python3
"""Compile production error rendering and helper wire errors with real bilingual resources.

The shared error struct is extracted unchanged from the macOS module because the
rest of SystemProxySettings imports SystemConfiguration. No proxy operation runs.
"""
import argparse,json,os,plistlib,shutil,subprocess,tempfile,sys
from pathlib import Path
from foundation_test_support import build_foundation_module
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
        for (failure, english, chinese) in [
            (DeviceCommandRunner.Failure.timedOut, "The device command exceeded its time limit.", "设备命令执行超时。"),
            (.cancelled, "The device command was cancelled.", "设备命令已取消。"),
            (.outputTooLarge, "The device command output exceeded its size limit.", "设备命令输出超过大小限制。"),
        ] {
            check(failure.localizedDescription == english, "device diagnostics remain stable")
            check(LocalizedErrorPresentation.message(for: failure) == (language == "en" ? english : chinese),
                  "device failure retains typed localization identity")
        }
        let timeout = OperationIssue.networkUpstreamResponseTimeout
        let captured = timeout.capturedFailure
        let persisted = try JSONEncoder().encode(captured)
        let restored = try JSONDecoder().decode(CapturedFailure.self, from: persisted)
        check(restored == captured, "captured failure identity roundtrip")
        check(restored.diagnostic == "Timed out waiting for the upstream response", "persisted diagnostic stays English")
        check(restored.localizedPresentation == (language == "en" ? restored.diagnostic : "等待上游响应超时"),
              "reopened failure renders selected language")
        let detail = "curl: (7) original 原文 100% %@"
        let parameterized = OperationIssue.networkUpstreamConnectionFailed(detail).capturedFailure
        check(parameterized.arguments == [detail], "failure stores parameters separately")
        check(parameterized.localizedPresentation == (language == "en" ? "Unable to connect to the upstream: " : "无法连接上游：") + detail,
              "foreign details are not translated or interpreted as a format")
        let numeric = OperationIssue.networkResponseHeadersTooLarge(65536).capturedFailure
        check(numeric.arguments == ["65536"], "numeric parameters persist canonically")
        check(numeric.localizedPresentation.contains("65536") || numeric.localizedPresentation.contains("65,536"), "numeric restoration uses its real type")
        let foreign = CapturedFailure(code: "external_detail", diagnostic: detail)
        check(foreign.localizedPresentation == detail, "foreign diagnostic is verbatim")
        let future = CapturedFailure(code: "future_failure", arguments: ["x"], diagnostic: detail)
        check(future.localizedPresentation == detail, "unknown future codes remain readable")
        let badArguments = CapturedFailure(code: numeric.code, arguments: ["not-an-integer"], diagnostic: detail)
        check(badArguments.localizedPresentation == detail, "malformed persisted parameters cannot reach printf")
        let modelFailure = OperationIssue.modelNetworkRandomDisconnect.capturedFailure
        check(modelFailure.localizedPresentation == (language == "en" ? "Network simulation: random disconnect" : "弱网模拟：随机断连"),
              "persisted model failures also resolve by code")
        let externalValidation = CapturedFailure(code: "external_proxy.external_invalid_target", arguments: ["invalid target"],
                                                diagnostic: "Invalid included target: invalid target")
        check(externalValidation.localizedPresentation == Strings.Integration.externalInvalidTarget("invalid target"),
              "proxy validation failures retain typed parameters")
        let curlFailure = NetworkFailure.capture(HTTPRequestTransport.Failure.curlFailure(7, detail))
        check(curlFailure.diagnostic == detail && curlFailure.localizedPresentation == detail,
              "actual HTTP transport keeps foreign curl stderr verbatim")
        let ownTransportTimeout = NetworkFailure.capture(HTTPRequestTransport.Failure.timedOut)
        check(ownTransportTimeout.code == "network_request_timeout", "transport own timeout is typed")
        check(ownTransportTimeout.localizedPresentation == (language == "en" ? "Request timed out" : "请求超时"),
              "transport own timeout uses selected language")
        let cancelled = DeviceCommandRunner.Cancellation(); cancelled.cancel()
        do {
            _ = try DeviceAutomation.adb(["devices"], cancellation: cancelled)
            preconditionFailure("cancelled device command")
        } catch {
            check((error as? OperationIssueProviding)?.operationIssue.code == "device_command_cancelled", "device wrapper retains failure code")
            check(LocalizedErrorPresentation.message(for: error) == (language == "en" ? "The device command was cancelled." : "设备命令已取消。"),
                  "device GUI path avoids nested English error descriptions")
        }
        print("PASS: \(count) production diagnostic/presentation/guide/transport checks [\(language)]")
    }
}
'''
def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--swiftc',default='swiftc');args=parser.parse_args();swiftc=shutil.which(args.swiftc) or args.swiftc
    with tempfile.TemporaryDirectory(prefix='pm-localized-errors-') as directory:
        folder=Path(directory); module_flags=build_foundation_module(swiftc, folder); entry=folder/'Checks.swift';entry.write_text('@_exported import ProxyMirrorFoundation\n' + MAIN)
        shared=(ROOT/'Sources/ProxyMirrorSystemProxy/SystemProxySettings.swift').read_text();start=shared.index('package struct SystemProxyError:');end=shared.index('\npackage final class SystemProxySettings',start)
        transport=folder/'SystemProxyError.swift';transport.write_text('import Foundation\n'+shared[start:end])
        library=folder/('libProxyMirrorSystemProxy.dylib' if sys.platform=='darwin' else 'libProxyMirrorSystemProxy.so')
        subprocess.run([swiftc,'-swift-version','5','-package-name','ProxyMirror','-emit-module','-emit-library','-module-name','ProxyMirrorSystemProxy','-emit-module-path',str(folder/'ProxyMirrorSystemProxy.swiftmodule'),str(transport),str(ROOT/'Sources/ProxyMirrorSystemProxy/SystemProxyBypassList.swift'),'-o',str(library)],check=True,timeout=120)
        source=['Localization/AppLanguage.swift','Localization/LocalizationContext.swift','Localization/LocalizationResources.swift','UI/PresentationLocalization.swift','System/LocalizedErrorPresentation.swift','System/GeneratedOperationIssues.swift','System/GeneratedModelOperationIssues.swift','System/ReleaseUpdate.swift','System/NetworkAccessPolicy.swift','System/NetworkFailure.swift','System/DeviceAutomation.swift','System/CertificatePlatformGuides.swift','Localization/Generated/Strings.swift','Localization/Generated/EnglishFallbacks.swift']
        paths=[]
        for relative in source:
            original=ROOT/'Sources/ProxyMirrorCore'/relative
            copied=folder/'production'/relative
            copied.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(original,copied)
            paths.append(str(copied))
        binary=folder/'checks'
        subprocess.run([swiftc,'-swift-version','5','-package-name','ProxyMirror','-module-cache-path',str(folder/'modules'),'-I',str(folder),'-L',str(folder),'-lProxyMirrorSystemProxy',*module_flags,'-Xlinker','-rpath','-Xlinker',str(folder),*paths,str(entry),'-o',str(binary)],check=True,timeout=180)
        bundle=folder/'Resources.bundle'
        shutil.copytree(ROOT/'Sources/ProxyMirrorCore/Resources',bundle)
        languages=[path.stem for path in bundle.glob('*.lproj')]
        (bundle/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'test.ProxyMirror.Errors','CFBundleDevelopmentRegion':'en','CFBundleLocalizations':languages}))
        for language in ['en','zh-Hans']:
            env=dict(os.environ,PM_SETTINGS_LANGUAGE=language,PM_LOCALIZATION_RESOURCE_DIR=str(bundle))
            subprocess.run([str(binary)],env=env,check=True,timeout=20)
if __name__=='__main__':main()
