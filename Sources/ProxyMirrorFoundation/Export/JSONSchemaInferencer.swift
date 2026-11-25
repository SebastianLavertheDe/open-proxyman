import Foundation
import CoreFoundation

/// Infers OpenAPI 3.0 schemas from observations, without treating absent fields as null.
package enum JSONSchemaInferencer {
    package static func infer(_ samples: [Any]) -> [String: Any] {
        infer(samples, depth: 0)
    }

    private static func kind(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if value is [String: Any] { return "object" }
        if value is [Any] { return "array" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return "boolean" }
            return number.doubleValue.rounded() == number.doubleValue ? "integer" : "number"
        }
        return "string"
    }

    private static func infer(_ samples: [Any], depth: Int) -> [String: Any] {
        guard depth < 40, !samples.isEmpty else { return [:] }
        let nullable = samples.contains { $0 is NSNull }
        let present = samples.filter { !($0 is NSNull) }
        guard !present.isEmpty else { return ["nullable": true] }
        var groups = Dictionary(grouping: present, by: kind)
        // Integers are valid numbers; prefer a single number schema to overlapping anyOf branches.
        if groups["number"] != nil, let integers = groups.removeValue(forKey: "integer") {
            groups["number", default: []].append(contentsOf: integers)
        }
        var schema: [String: Any]
        if groups.count > 1 {
            schema = ["anyOf": groups.keys.sorted().map { infer(groups[$0]!, depth: depth + 1) }]
        } else {
            let type = groups.keys.first!
            schema = ["type": type]
            switch type {
            case "object":
                let objects = present.compactMap { $0 as? [String: Any] }
                let keys = Set(objects.flatMap { $0.keys }).sorted()
                schema["properties"] = Dictionary(uniqueKeysWithValues: keys.map { key in
                    (key, infer(objects.compactMap { $0[key] }, depth: depth + 1))
                })
                let required = keys.filter { key in objects.allSatisfy { $0[key] != nil } }
                if !required.isEmpty { schema["required"] = required }
            case "array":
                schema["items"] = infer(present.compactMap { $0 as? [Any] }.flatMap { $0 }, depth: depth + 1)
            case "string":
                let values = present.compactMap { $0 as? String }
                let unique = Set(values)
                if values.count >= 3, unique.count <= 5 { schema["enum"] = unique.sorted() }
            default: break
            }
        }
        if nullable {
            // In OpenAPI 3.0 nullable only applies when type is declared. Mixed
            // schemas therefore make every anyOf branch nullable explicitly.
            if let alternatives = schema["anyOf"] as? [[String: Any]] {
                schema["anyOf"] = alternatives.map { branch -> [String: Any] in
                    var branch = branch; branch["nullable"] = true; return branch
                }
            } else {
                schema["nullable"] = true
                if let values = schema["enum"] as? [Any] { schema["enum"] = values + [NSNull()] }
            }
        }
        return schema
    }
}
