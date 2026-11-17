import ProxyMirrorCoreChecks

func runCoreUnitChecks() {
    for group in CoreCheckGroup.allCases {
        runCoreCheck(group)
    }
}

func runCoreCheck(named name: String) -> Bool {
    guard let group = CoreCheckGroup(rawValue: name) else { return false }
    runCoreCheck(group)
    return true
}

func runCoreCheck(_ group: CoreCheckGroup) {
    MainActor.assumeIsolated {
        do {
            try group.run { condition, message, _, _ in check(condition, message) }
        } catch {
            check(false, "Core checks \(group.rawValue): \(error)")
        }
    }
}
