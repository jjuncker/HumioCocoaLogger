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
    public var cachePolicy:NSURLRequest.CachePolicy = .useProtocolCachePolicy
    public var timeout:TimeInterval = 10
    public var postFrequency:TimeInterval = 10
    public var retryCount:Int = 2
    public var allowsCellularAccess = true
    public var ommitEscapeCharacters = false

    public static func defaultConfiguration() -> HumioLoggerConfiguration {
        return HumioLoggerConfiguration()
    }
}

public protocol HumioLogger: DDLogger  {
    func setVerbose(verbose:Bool)
}

public class HumioLoggerFactory {
    public class func createLogger(serviceUrl:URL? = nil, accessToken:String?=nil, dataSpace:String?=nil, loggerId:String=NSUUID().uuidString, tags:[String:String] = HumioLoggerFactory.defaultTags(), configuration:HumioLoggerConfiguration=HumioLoggerConfiguration.defaultConfiguration()) -> HumioLogger {
        return HumioCocoaLumberjackLogger(accessToken: accessToken, dataSpace: dataSpace, serviceUrl:serviceUrl, loggerId:loggerId, tags: tags, configuration: configuration)
    }

    public class func defaultTags() -> [String:String] {
        return [
            "platform":"ios",
            "bundleIdentifier": (Bundle.main.object(forInfoDictionaryKey: "CFBundleIdentifier") ?? "unknown") as! String,
            "source":HumioCocoaLumberjackLogger.LOGGER_NAME
        ]
    }
}

class HumioCocoaLumberjackLogger: DDAbstractLogger {
    private let loggerId:String

    fileprivate var taskDescriptionToCount = [String:Int]()
    fileprivate static let LOGGER_NAME = "MobileDeviceLogger"
    fileprivate static let HUMIO_ENDPOINT_FORMAT = "https://cloud.humio.com/api/v1/dataspaces/%@/ingest"

    private let accessToken:String
    private var session:URLSession!
    private let humioServiceUrl:URL
    private let cachePolicy:URLRequest.CachePolicy
    private let timeout:TimeInterval
    private let tags:[String:String]
    private let postFrequency:TimeInterval
    private let retryCount:Int
    private let attributes:[String:String]
    private let ommitEscapeCharacters:Bool

    private let bundleVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown") as! String
    private let bundleShortVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown") as! String
    private let deviceName = UIDevice.current.name

    fileprivate let humioQueue:OperationQueue
    private var timer:Timer?

    internal var cache:[Any]
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
    
    init(accessToken:String?=nil, dataSpace:String?=nil, serviceUrl:URL? = nil, loggerId:String, tags:[String:String], configuration:HumioLoggerConfiguration) {
        self.loggerId = loggerId

        var setToken:String? = accessToken
        setToken = setToken ?? Bundle.main.infoDictionary!["HumioAccessToken"] as? String

        var setSpace:String? = dataSpace
        setSpace = setSpace ?? Bundle.main.infoDictionary!["HumioDataSpace"] as? String

        guard let space = setSpace, let token = setToken, space.characters.count > 0 && token.characters.count > 0 else {
            fatalError("dataSpace [\(setSpace)] or accessToken [\(setToken)] not properly set for humio")
        }

        self.humioServiceUrl = serviceUrl ?? URL(string: String(format: HumioCocoaLumberjackLogger.HUMIO_ENDPOINT_FORMAT, space))!
        self.accessToken = setToken!

        self.cachePolicy = configuration.cachePolicy
        self.timeout = configuration.timeout
        self.tags = tags
        self._verbose = false
        self.postFrequency = configuration.postFrequency
        self.retryCount = configuration.retryCount
        self.ommitEscapeCharacters = configuration.ommitEscapeCharacters

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.allowsCellularAccess = configuration.allowsCellularAccess
        sessionConfiguration.timeoutIntervalForResource = timeout
        
        self.cache = [Any]()
        
        self.humioQueue = OperationQueue()
        humioQueue.qualityOfService = .background
        humioQueue.maxConcurrentOperationCount = 1
        self.attributes = ["loggerId":self.loggerId, "deviceName":self.deviceName, "CFBundleVersion":self.bundleVersion, "CFBundleShortVersionString":self.bundleShortVersion]

        super.init()
        
        let operationQueue = OperationQueue()
        operationQueue.qualityOfService = .background
        operationQueue.maxConcurrentOperationCount = 1
        
        self.session = URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: operationQueue)
        self.logFormatter = SimpleHumioLogFormatter()

        DispatchQueue.main.async {
            self.timer = Timer.scheduledTimer(timeInterval: self.postFrequency, target: self, selector: #selector(self.ingest), userInfo: nil, repeats: true)
        }
    }


    override func log(message: DDLogMessage!) {
        var messageText = message.message
        if let logFormatter = internalLogFormatter {
            messageText = logFormatter.format(message: message)
        }

        let event = ["timestamp":Date().timeIntervalSince1970*1000, //ms
                     "kvparse":true,
                     "attributes":self.attributes,
                     "rawstring":ommitEscapeCharacters ? messageText!.replacingOccurrences(of: "\\", with: "") : messageText!
                    ] as [String : Any]

        self.humioQueue.addOperation {
            self.cache.append(event)
        }
    }

    @objc func ingest() {
        self.humioQueue.isSuspended = true

        let eventsToPost = [Any](self.cache)
        if (eventsToPost.count == 0) {
            self.humioQueue.isSuspended = false
            return
        }

        let postBlock = BlockOperation() {
            self.cache.removeAll()
            if let request = self.createRequest(events: eventsToPost) {
                self.sendRequest(request: request)
            }
        }

        self.humioQueue.operations.forEach({ op in
            op.addDependency(postBlock)
        })

        self.humioQueue.addOperation(postBlock)
        self.humioQueue.isSuspended = false
    }

    private func createRequest(events:[Any]) -> URLRequest? {
        let jsonDict:[NSDictionary] = [["tags": self.tags,
            "events": events
            ]]

        if (self._verbose) {
            print("HumioCocoaLumberjackLogger: About to post \(events.count) events")
        }

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: jsonDict, options:[])
            var request = URLRequest(url:self.humioServiceUrl, cachePolicy: self.cachePolicy, timeoutInterval: self.timeout)
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.addValue("Bearer " + self.accessToken, forHTTPHeaderField: "Authorization")
            
            request.httpBody = jsonData
            request.httpMethod = "POST"

            return request
        } catch {
            if self._verbose {
                print("HumioCocoaLumberjackLogger: Failed to add requst to humio. Most likely the JSON is invalid: \(jsonDict)")
            }
        }
        return nil
    }

    fileprivate func sendRequest(request:URLRequest, taskDescription:String = UUID().uuidString) {
        self.humioQueue.addOperation {
            let requestCount = self.taskDescriptionToCount[taskDescription] ?? 0
            if requestCount > self.retryCount {
                if self._verbose {
                    print("HumioCocoaLumberjackLogger: Giving up on request after \(self.retryCount) retries")
                }
                self.taskDescriptionToCount.removeValue(forKey: taskDescription)
                return
            }

            self.taskDescriptionToCount[taskDescription] = requestCount + 1
            let task = self.session.dataTask(with: request)
            task.taskDescription = taskDescription
            task.resume()
        }
    }

    override var loggerName: String! {
        get {
            return HumioCocoaLumberjackLogger.LOGGER_NAME
        }
    }
    
    override func flush() {
        self.session.flush {}
    }
}

extension HumioCocoaLumberjackLogger : URLSessionDataDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if self._verbose {
            print("HumioCocoaLumberjackLogger: request", task.originalRequest!.allHTTPHeaderFields!, "body: ", String(data: task.originalRequest!.httpBody!, encoding: String.Encoding.utf8)!)
            print("HumioCocoaLumberjackLogger: response", task.response!)
        }

        if let originalRequest = task.originalRequest, error != nil {
            if self._verbose {
                print("HumioCocoaLumberjackLogger: failed to send data, retrying in 5 seconds. Error \(error)")
            }

            DispatchQueue.global(qos: .background).asyncAfter(deadline: DispatchTime.now() + 5.0, execute: {
                self.sendRequest(request: originalRequest, taskDescription: task.taskDescription!)
            })
        } else {
            self.humioQueue.addOperation {
                self.taskDescriptionToCount.removeValue(forKey: task.taskDescription!)
            }
        }
    }
}

final class SimpleHumioLogFormatter: NSObject, DDLogFormatter {
    func format(message: DDLogMessage!) -> String! {
        return "logLevel=\(self.logLevelString(message)) filename='\(message.fileName ?? "")' line=\(message.line) \(message.message ?? "")"
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
