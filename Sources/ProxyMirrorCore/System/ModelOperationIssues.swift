import Foundation

extension OperationIssue {
    /// 保留子错误的稳定诊断，同时延迟渲染规则名称和本地化说明。
    static func modelRuleValidation(ruleName: String, issue: OperationIssue) -> Self {
        Self(code: "models.rule_validation." + issue.code,
             diagnostic: ruleName + ": " + issue.diagnostic,
             render: { Strings.Models.validationRuleContext(ruleName, issue.localizedPresentation) })
    }
}
