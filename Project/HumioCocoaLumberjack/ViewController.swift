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
        DDLogInfo("Info");
        DDLogWarn("Warn");
        
        DDLogError("user=asdf app=test");
        DDLogDebug("msg='Some random message'");

        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 1) {
            DDLogError("user=asdf2 app=test2");
        }
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 2) {
            DDLogError("user=asdf3 app=test3");
        }
    }
}
