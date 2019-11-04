//
//  SessionManagerDelegate.swift
//  QRchestra
//
//  Created by Wenzhong Zhang on 2019-11-04.
//  Copyright © 2019 Wenzhong Zhang. All rights reserved.
//

import Foundation

protocol SessionManagerDelegate: class {
    func sessionManager(_ sessionManager: SessionManager, didStopRunningWithError error: Error)
}
