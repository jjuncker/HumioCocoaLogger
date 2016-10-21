//
//  ViewController.swift
//  HumioCocoaLumberjack
//
//  Created by Jimmy Juncker on 06/06/16.
//

import UIKit
import CocoaLumberjack

class ViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        DDLogVerbose("Verbose");
        DDLogDebug("Debug");
        DDLogInfo("Info");
        DDLogWarn("Warn");
        
        DDLogError("user=asdf app=test");

    }
}
