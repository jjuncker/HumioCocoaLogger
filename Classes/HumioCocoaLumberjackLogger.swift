//
//  HumioLogger.swift
//  HumioCocoaLumberjack
//
//  Created by Jimmy Juncker on 06/06/16.
//

import UIKit
import CocoaLumberjack
import CoreFoundation

public struct HumioLoggerConfiguration {
    var cachePolicy:NSURLRequest.CachePolicy = .useProtocolCachePolicy
    var timeout:TimeInterval = 10
    var allowsCellularAccess = true
    var bulkSize = 1

    static func defaultConfiguration() -> HumioLoggerConfiguration {
        return HumioLoggerConfiguration()
    }
}

public protocol HumioLogger: DDLogger  {
    func setVerbose(verbose:Bool)
}

public class HumioLoggerFactory {
    public class func createLogger(accessToken:String?=nil, dataSpace:String?=nil, loggerId:String=NSUUID().uuidString, tags:[String:String] = HumioLoggerFactory.defaultTags(), configuration:HumioLoggerConfiguration=HumioLoggerConfiguration.defaultConfiguration()) -> HumioLogger {
        return HumioCocoaLumberjackLogger(accessToken: accessToken, dataSpace: dataSpace, loggerId:loggerId, tags: tags, configuration: configuration)
    }

    public class func defaultTags() -> [String:String] {
        return [
            "platform":"ios",
            "bundleIdentifier": (Bundle.main.object(forInfoDictionaryKey: "CFBundleIdentifier") ?? "unknown") as! String,
            "source":HumioCocoaLumberjackLogger.LOGGER_NAME
        ]
    }
}

//TODO - store cache on filesystem + add encryption

class HumioCocoaLumberjackLogger: DDAbstractLogger {
    private let loggerId:String

    fileprivate static let LOGGER_NAME = "MobileDeviceLogger"
    private static let HUMIO_ENDPOINT_FORMAT = "https://cloud.humio.com/api/v1/dataspaces/%@/ingest"
    private let accessToken:String
    private var session:URLSession!
    private let humioServiceUrl:URL
    private let cachePolicy:URLRequest.CachePolicy
    private let timeout:TimeInterval
    private let tags:[String:String]
    private let bulksize:Int
    private let attributes:[String:String]

    private let bundleVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown") as! String
    private let bundleShortVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown") as! String
    private let deviceName = UIDevice.current.name


    internal var cache:[[String:Any]]
    private let logQueue:OperationQueue
    
    internal var _verbose:Bool

    // ###########################################################################
    // Fails when formatting using the logformatter from parent
    //
    // https://github.com/CocoaLumberjack/CocoaLumberjack/issues/643
    //
    private var internalLogFormatter: DDLogFormatter?
    
    override internal var logFormatter: DDLogFormatter! {
        set {
            super.logFormatter = newValue
            internalLogFormatter = newValue
        }
        get {
            return super.logFormatter
        }
    }
    // ###########################################################################
    
    init(accessToken:String?=nil, dataSpace:String?=nil, loggerId:String, tags:[String:String], configuration:HumioLoggerConfiguration) {
        self.loggerId = loggerId

        var setToken:String? = accessToken
        setToken = setToken ?? Bundle.main.infoDictionary!["HumioAccessToken"] as? String

        var setSpace:String? = dataSpace
        setSpace = setSpace ?? Bundle.main.infoDictionary!["HumioDataSpace"] as? String

        guard let space = setSpace, let token = setToken, space.characters.count > 0 && token.characters.count > 0 else {
            fatalError("dataSpace [\(setSpace)] or accessToken [\(setToken)] not properly set for humio")
        }

        self.humioServiceUrl = URL(string: String(format: HumioCocoaLumberjackLogger.HUMIO_ENDPOINT_FORMAT, space))!
        self.accessToken = setToken!

        self.cachePolicy = configuration.cachePolicy
        self.timeout = configuration.timeout
        self.tags = tags
        self._verbose = false
        self.bulksize = configuration.bulkSize
        
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.allowsCellularAccess = configuration.allowsCellularAccess
        sessionConfiguration.timeoutIntervalForResource = timeout
        
        self.cache = [[String:AnyObject]]()
        
        self.logQueue = OperationQueue()
        logQueue.qualityOfService = .background
        logQueue.maxConcurrentOperationCount = 1

        self.attributes = ["loggerId":self.loggerId, "deviceName":self.deviceName, "CFBundleVersion":self.bundleVersion, "CFBundleShortVersionString":self.bundleShortVersion]

        super.init()
        
        let operationQueue = OperationQueue()
        operationQueue.qualityOfService = .background
        operationQueue.maxConcurrentOperationCount = 1
        
        self.session = URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: operationQueue)
        self.logFormatter = SimpleHumioLogFormatter()

    }


    override func log(message: DDLogMessage!) {
        var messageText = message.message
        if let logFormatter = internalLogFormatter {
            messageText = logFormatter.format(message: message)
        }


        let event = ["timestamp":Date().timeIntervalSince1970*1000, //ms
                     "kvparse":true,
                     "attributes":self.attributes,
                     "rawstring":messageText!
                    ] as [String : Any]

        self.logQueue.addOperation {
            if (self.bulksize <= 1 && self.cache.count == 0) {
                self.postEvents(events: [event])
            } else {
                self.cache.append(event)
                self.postEvents(events: self.cache)
            }
        }
    }
    
    private func postEvents(events:[[String:Any]]) {
        let jsonDict:[NSDictionary] = [["tags": self.tags,
            "events": events
            ]]
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: jsonDict,
                                                      options:.prettyPrinted)
            var request = URLRequest(url:self.humioServiceUrl, cachePolicy: self.cachePolicy, timeoutInterval: self.timeout)
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.addValue("Bearer " + self.accessToken, forHTTPHeaderField: "Authorization")
            
            request.httpBody = jsonData
            request.httpMethod = "POST"
            
            let task = self.session.dataTask(with: request)
            task.resume()
        } catch { 
            if self._verbose {
                print("failed to add requst to humio")
            }
        }
    }
    
    override var loggerName: String! { get {
        return HumioCocoaLumberjackLogger.LOGGER_NAME
        }
    }
    
    override func flush() {
        self.session.flush {
        }
    }
}

extension HumioCocoaLumberjackLogger : URLSessionDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if self._verbose {
            print("HumioCocoaLumberjackLogger: request", task.originalRequest!.allHTTPHeaderFields!, "body: ", String(data: task.originalRequest!.httpBody!, encoding: String.Encoding.utf8)!)
            print("HumioCocoaLumberjackLogger: response", task.response!)
        }

        if (error == nil) {
            //TODO this may remove unsend entries
            self.cache.removeAll()
        }
    }
}

final class SimpleHumioLogFormatter: NSObject, DDLogFormatter {
    func format(message: DDLogMessage!) -> String! {
        return "logLevel=\(self.logLevelString(message)) filename='\(message.fileName)' line=\(message.line) \(message.message)"
    }
    
    func logLevelString(_ logMessage: DDLogMessage!) -> String {
        let logLevel: String
        let logFlag = logMessage.flag
        if logFlag.contains(.error) {
            logLevel = "ERROR"
        } else if logFlag.contains(.warning) {
            logLevel = "WARNING"
        } else if logFlag.contains(.info) {
            logLevel = "INFO"
        } else if logFlag.contains(.debug) {
            logLevel = "DEBUG"
        } else if logFlag.contains(.verbose) {
            logLevel = "VERBOSE"
        } else {
            logLevel = "UNKNOWN"
        }
        return logLevel
    }
}

extension HumioCocoaLumberjackLogger: HumioLogger {
    func setVerbose(verbose: Bool) {
        self._verbose = verbose
    }
}
