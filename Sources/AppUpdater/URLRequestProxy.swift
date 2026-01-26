//
//  File 2.swift
//  
//
//  Created by lixindong on 2024/7/22.
//

import Foundation

/// url request proxy
/// Implement any one of the three apply methods.
open class URLRequestProxy: NSObject {
    open func apply(to request: URLRequest) throws -> URLRequest  {
        guard let url = request.url else {
            throw AUProxyError.invalidURL
        }
        return try apply(to: url).request
    }
    
    open func apply(to url: URL) throws -> URL {
        let urlString = apply(to: url.absoluteString)
        guard let result = URL(string: urlString) else {
            throw AUProxyError.invalidURL
        }
        return result
    }
    
    open func apply(to urlString: String) -> String {
        return urlString
    }
}

public enum AUProxyError: Error {
    case invalidURL
}

extension URLRequest {
    @available(*, deprecated, renamed: "apply(proxy:)")
    public func applyWithThrowing(proxy: URLRequestProxy) throws -> URLRequest {
        try proxy.apply(to: self)
    }

    public func apply(proxy: URLRequestProxy) throws -> URLRequest {
        try proxy.apply(to: self)
    }
    
    public func apply(proxy: URLRequestProxy?) -> URLRequest? {
        try? proxy?.apply(to: self)
    }
}

/// candy
extension URLRequest {
    public func applyOrOriginal(proxy: URLRequestProxy?) -> URLRequest {
        apply(proxy: proxy) ?? self
    }
}
