import SwiftUI

struct BodyQueryView: View {
    let data: Data
    let unavailableReason: String?

    @State private var language = BodyQuery.Language.jsonPath
    @State private var expression = "$"
    @State private var worker: Task<BodyQuery.Result, Error>?
    @State private var runID: UUID?
    @State private var result: BodyQuery.Result?
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Picker(Strings.Detail.queryLanguage, selection: $language) {
                    ForEach(BodyQuery.Language.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .onChange(of: language) { value in
                    expression = value == .jsonPath ? "$" : "."
                    clearResult()
                }
                if worker == nil {
                    Button(Strings.Detail.run) { run() }
                        .disabled(unavailableReason != nil || expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button(Strings.Detail.cancel) {
                        clearResult()
                        message = Strings.Detail.queryCancelled
                    }
                }
            }
            TextField(language == .jsonPath ? "$.items[*].name" : ".items[] | .name", text: $expression)
                .font(.system(.caption, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(Strings.Detail.queryExpression)
                .onSubmit { if worker == nil { run() } }
                .onChange(of: expression) { _ in clearResult() }
            if let detail = unavailableReason ?? message {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(failed ? Color.red : Color.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if worker != nil {
                ProgressView(Strings.Detail.querying).font(.caption).controlSize(.small)
            }
            if let result {
                HStack {
                    if let count = result.matches {
                        Text(Strings.Detail.matches(count))
                    } else {
                        Text(result.text.isEmpty ? Strings.Detail.noOutput : Strings.Detail.queryResults)
                    }
                    Spacer()
                    if !result.text.isEmpty {
                        Button(Strings.Detail.copyResult) { CopyPaste.copy(result.text) }.buttonStyle(.plain)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if result.truncated {
                    Text(Strings.Detail.resultPreviewIsLimitedToTheFirst512Kib)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                ScrollView([.horizontal, .vertical]) {
                    Text(result.text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
            } else {
                Spacer(minLength: 0)
            }
        }
        .controlSize(.small)
        .padding(8)
        .onDisappear { worker?.cancel() }
    }

    private func clearResult() {
        runID = nil
        worker?.cancel()
        worker = nil
        result = nil
        message = nil
        failed = false
    }

    private func run() {
        guard unavailableReason == nil else { return }
        clearResult()
        let id = UUID()
        runID = id
        let request = Task.detached(priority: .userInitiated) { [expression, language, data] in
            try await BodyQuery.run(expression, language: language, data: data)
        }
        worker = request
        Task { @MainActor in
            let outcome = await request.result
            guard id == runID else { return }
            worker = nil
            switch outcome {
            case .success(let value):
                result = value
            case .failure(let error):
                failed = !(error is CancellationError)
                message = failed ? LocalizedErrorPresentation.message(for: error) : Strings.Detail.queryCancelled
            }
        }
    }
}
