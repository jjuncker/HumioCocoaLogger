//
//  HumioLogger.swift
//  HumioCocoaLumberjack
//
//  Created by Jimmy Juncker on 06/06/16.
//

import UIKit
import CocoaLumberjack

//TODO - store cache on filesystem + add encryption

class HumioCocoaLumberjackLogger: DDAbstractLogger {
    private static let LOGGER_NAME = "HumioLogger"
    private static let HUMIO_ENDPOINT_FORMAT = "https://cloud.humio.com/api/v1/dataspaces/%@/ingest"
    private let accessToken:String
    private var session:NSURLSession!
    private let humioServiceUrl:NSURL
    private let cachePolicy:NSURLRequestCachePolicy
    private let timeout:NSTimeInterval
    private let tags:[String:String]
    private let bulksize:Int
    
    internal var cache:[NSDictionary]
    private let logQueue:NSOperationQueue
    
    var verbose:Bool

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
    
    convenience init(accessToken:String? = nil, dataSpace:String? = nil, tags:[String:String]?=nil, bulksize:Int=1) {
        self.init(accessToken:accessToken, cachePolicy: .UseProtocolCachePolicy, dataSpace:dataSpace, tags: tags)
    }
    
    init(accessToken:String?=nil, cachePolicy:NSURLRequestCachePolicy, dataSpace:String?=nil, tags:[String:String]?=nil, bulksize:Int=1,timeout:NSTimeInterval=10, allowsCellularAccess:Bool=false) {
        
        var token:String? = accessToken
        token = token ?? NSBundle.mainBundle().infoDictionary!["HumioAccessToken"] as? String

        var space:String?? = dataSpace
        space = space ?? NSBundle.mainBundle().infoDictionary!["HumioDataSpace"] as? String
        
        if let space = space, let token = token {
            self.humioServiceUrl = NSURL(string: String(format: HumioCocoaLumberjackLogger.HUMIO_ENDPOINT_FORMAT, space ?? ""))!
            self.accessToken = token
        } else {
            fatalError("dataSpace or accessToken not properly set for humio")
        }
        
        self.cachePolicy = cachePolicy
        self.timeout = timeout
        if let tags = tags {
            self.tags = tags
        } else {
            self.tags = ["platform":"ios",
                         "CFBundleIdentifier": (NSBundle.mainBundle().objectForInfoDictionaryKey("CFBundleIdentifier") ?? "unknown bundle CFBundleIdentifier") as! String,
                         "source":HumioCocoaLumberjackLogger.LOGGER_NAME,
                         "CFBundleShortVersionString": (NSBundle.mainBundle().objectForInfoDictionaryKey("CFBundleShortVersionString") ?? "unknown bundle CFBundleShortVersionString") as! String,
                         "CFBundleVersion": (NSBundle.mainBundle().objectForInfoDictionaryKey("CFBundleVersion") ?? "unknown bundle CFBundleVersion") as! String
            ]
        }
        self.verbose = false
        self.bulksize = bulksize
        
        let sessionConfiguration = NSURLSessionConfiguration.ephemeralSessionConfiguration()
        sessionConfiguration.allowsCellularAccess = allowsCellularAccess
        sessionConfiguration.timeoutIntervalForResource = timeout
        
        self.cache = [[String:AnyObject]]()
        
        self.logQueue = NSOperationQueue()
        logQueue.qualityOfService = .Background
        logQueue.maxConcurrentOperationCount = 1

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
                     "rawstring":messageText
                    ]
        
        self.logQueue.addOperationWithBlock {
            if (self.bulksize <= 1) {
                self.postEvents([event])
            } else if (self.cache.count < self.bulksize - 1) {
                self.cache.append(event)
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
        if self.verbose {
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
        return "filename=\(logMessage.fileName) line=\(logMessage.line) logLevel=\(self.logLevelString(logMessage)) \(logMessage.message)"
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
