//
//  AppDelegate.swift
//  HumioCocoaLumberjack
//
//  Created by Jimmy Juncker on 06/06/16.
//

import UIKit
import CocoaLumberjack

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(application: UIApplication, didFinishLaunchingWithOptions launchOptions: [NSObject: AnyObject]?) -> Bool {
        DDLog.addLogger(DDTTYLogger.sharedInstance())
        
        //let logger = HumioLogger(accessToken: "your token here", dataSpace:"some dataspace")
        
        //or if you set up the info plist:
        let logger = HumioLogger()

        //logger.verbose = true //prints the requests/responses from humio
        
        DDLog.addLogger(logger, withLevel:.Error)
        DDLog.setLevel(.Error, forClass: HumioLogger.self)
                
        return true
    }
}
