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
    var cachePolicy:NSURLRequestCachePolicy = .UseProtocolCachePolicy
    var timeout:NSTimeInterval = 10
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
    public class func createLogger(accessToken:String?=nil, dataSpace:String?=nil, loggerId:String=NSUUID().UUIDString, tags:[String:String] = HumioLoggerFactory.defaultTags(), configuration:HumioLoggerConfiguration=HumioLoggerConfiguration.defaultConfiguration()) -> HumioLogger {
        return HumioCocoaLumberjackLogger(accessToken: accessToken, dataSpace: dataSpace, loggerId:loggerId, tags: tags, configuration: configuration)
    }

    public class func defaultTags() -> [String:String] {
        return [
            "platform":"ios",
            "bundleIdentifier": (NSBundle.mainBundle().objectForInfoDictionaryKey("CFBundleIdentifier") ?? "unknown") as! String,
            "source":HumioCocoaLumberjackLogger.LOGGER_NAME
        ]
    }
}

//TODO - store cache on filesystem + add encryption

class HumioCocoaLumberjackLogger: DDAbstractLogger {
    private let loggerId:String

    private static let LOGGER_NAME = "MobileDeviceLogger"
    private static let HUMIO_ENDPOINT_FORMAT = "https://cloud.humio.com/api/v1/dataspaces/%@/ingest"
    private let accessToken:String
    private var session:NSURLSession!
    private let humioServiceUrl:NSURL
    private let cachePolicy:NSURLRequestCachePolicy
    private let timeout:NSTimeInterval
    private let tags:[String:String]
    private let bulksize:Int
    private let attributes:[String:String]

    private let bundleVersion = (NSBundle.mainBundle().objectForInfoDictionaryKey("CFBundleVersion") ?? "unknown") as! String
    private let bundleShortVersion = (NSBundle.mainBundle().objectForInfoDictionaryKey("CFBundleShortVersionString") ?? "unknown") as! String
    private let deviceName = UIDevice.currentDevice().name


    internal var cache:[NSDictionary]
    private let logQueue:NSOperationQueue
    
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

        var token:String? = accessToken
        token = token ?? NSBundle.mainBundle().infoDictionary!["HumioAccessToken"] as? String

        var space:String? = dataSpace
        space = space ?? NSBundle.mainBundle().infoDictionary!["HumioDataSpace"] as? String
        
        if space?.characters.count > 0 && token?.characters.count > 0 {
            self.humioServiceUrl = NSURL(string: String(format: HumioCocoaLumberjackLogger.HUMIO_ENDPOINT_FORMAT, space! ?? ""))!
            self.accessToken = token!
        } else {
            fatalError("dataSpace [\(space)] or accessToken [\(token)] not properly set for humio")
        }
        
        self.cachePolicy = configuration.cachePolicy
        self.timeout = configuration.timeout
        self.tags = tags
        self._verbose = false
        self.bulksize = configuration.bulkSize
        
        let sessionConfiguration = NSURLSessionConfiguration.ephemeralSessionConfiguration()
        sessionConfiguration.allowsCellularAccess = configuration.allowsCellularAccess
        sessionConfiguration.timeoutIntervalForResource = timeout
        
        self.cache = [[String:AnyObject]]()
        
        self.logQueue = NSOperationQueue()
        logQueue.qualityOfService = .Background
        logQueue.maxConcurrentOperationCount = 1

        self.attributes = ["loggerId":self.loggerId, "deviceName":self.deviceName, "CFBundleVersion":self.bundleVersion, "CFBundleShortVersionString":self.bundleShortVersion]

        super.init()
        
        let operationQueue = NSOperationQueue()
        operationQueue.qualityOfService = .Background
        operationQueue.maxConcurrentOperationCount = 1
        
        self.session = NSURLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: operationQueue)
        self.logFormatter = SimpleHumioLogFormatter()

    }
    
    override func logMessage(logMessage: DDLogMessage!) {
        var messageText = logMessage.message
        if let logFormatter = internalLogFormatter {
            messageText = logFormatter.formatLogMessage(logMessage)
        }


        let event = ["timestamp":NSDate().timeIntervalSince1970*1000, //ms
                     "kvparse":true,
                     "attributes":self.attributes,
                     "rawstring":messageText
                    ]

        self.logQueue.addOperationWithBlock {
            if (self.bulksize <= 1 && self.cache.count == 0) {
                self.postEvents([event])
            } else {
                self.cache.append(event)
                self.postEvents(self.cache)
            }
        }
    }
    
    private func postEvents(events:[NSDictionary]) {
        let jsonDict:[NSDictionary] = [["tags": self.tags,
            "events": events
            ]]
        
        do {
            let jsonData = try NSJSONSerialization.dataWithJSONObject(jsonDict,
                                                                      options:.PrettyPrinted)
            let request = NSMutableURLRequest(URL:self.humioServiceUrl, cachePolicy: self.cachePolicy, timeoutInterval: self.timeout)
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.addValue("Bearer " + self.accessToken, forHTTPHeaderField: "Authorization")
            
            request.HTTPBody = jsonData
            request.HTTPMethod = "POST"
            
            let task = self.session.dataTaskWithRequest(request)
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
        self.session.flushWithCompletionHandler { 
        }
    }
}

extension HumioCocoaLumberjackLogger : NSURLSessionDelegate {
    func URLSession(session: NSURLSession, task: NSURLSessionTask, didCompleteWithError error: NSError?) {
        if self._verbose {
            print("HumioCocoaLumberjackLogger: request", task.originalRequest!.allHTTPHeaderFields, "body: ", NSString(data: task.originalRequest!.HTTPBody!, encoding: NSUTF8StringEncoding))
            print("HumioCocoaLumberjackLogger: response", task.response)
        }
        
        if (error == nil) {
            //TODO this may remove unsend entries
            self.cache.removeAll()
        }
    }
}

final class SimpleHumioLogFormatter: NSObject, DDLogFormatter {
    func formatLogMessage(logMessage: DDLogMessage!) -> String! {
        return "logLevel=\(self.logLevelString(logMessage)) filename='\(logMessage.fileName)' line=\(logMessage.line) \(logMessage.message)"
    }
    
    func logLevelString(logMessage: DDLogMessage!) -> String {
        let logLevel: String
        let logFlag = logMessage.flag
        if logFlag.contains(.Error) {
            logLevel = "ERROR"
        } else if logFlag.contains(.Warning) {
            logLevel = "WARNING"
        } else if logFlag.contains(.Info) {
            logLevel = "INFO"
        } else if logFlag.contains(.Debug) {
            logLevel = "DEBUG"
        } else if logFlag.contains(.Verbose) {
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
