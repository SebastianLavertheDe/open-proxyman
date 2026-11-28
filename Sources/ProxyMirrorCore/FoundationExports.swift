// Shared package APIs are available to desktop integration and its checks.
@_exported import ProxyMirrorFoundation

// Keep the desktop module's HTTP names unambiguous beside NIOHTTP1's models.
// These are aliases to the production Foundation types, not duplicate models.
public typealias HTTPMethod = ProxyMirrorFoundation.HTTPMethod
public typealias HTTPHeaders = ProxyMirrorFoundation.HTTPHeaders
public typealias HTTPRequestHead = ProxyMirrorFoundation.HTTPRequestHead
public typealias HTTPResponseHead = ProxyMirrorFoundation.HTTPResponseHead
public typealias HTTPParseError = ProxyMirrorFoundation.HTTPParseError
public typealias RequestHeadParser = ProxyMirrorFoundation.RequestHeadParser
public typealias ResponseHeadParser = ProxyMirrorFoundation.ResponseHeadParser
public typealias ChunkedTracker = ProxyMirrorFoundation.ChunkedTracker
public typealias URLParser = ProxyMirrorFoundation.URLParser
