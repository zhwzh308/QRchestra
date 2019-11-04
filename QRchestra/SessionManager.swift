//
//  SessionManager.swift
//  QRchestra
//
//  Created by Wenzhong Zhang on 2019-11-04.
//  Copyright © 2019 Wenzhong Zhang. All rights reserved.
//

import os.log
import AVFoundation
import UIKit

final class SessionManager: NSObject {
    weak var delegate: SessionManagerDelegate?
    var session: AVCaptureSession? {
        _session
    }
    var exposureMode: AVCaptureDevice.ExposureMode {
        didSet {
            let capture = exposureMode
            _sessionQueue.async {
                guard
                    let device = self._videoInput?.device,
                    device.isExposureModeSupported(capture),
                    device.exposureMode != capture
                    else {
                        return
                }
                do {
                    try device.lockForConfiguration()
                    defer {
                        device.unlockForConfiguration()
                    }
                    device.exposureMode = capture
                } catch {
                    debugPrint(error)
                }
            }
        }
    }
    var focusMode: AVCaptureDevice.FocusMode {
        didSet {
            let capture = focusMode
            _sessionQueue.async {
                guard
                    let device = self._videoInput?.device,
                    device.isFocusModeSupported(capture),
                    device.focusMode != capture
                    else {
                        return
                }
                do {
                    try device.lockForConfiguration()
                    defer {
                        device.unlockForConfiguration()
                    }
                    device.focusMode = capture
                } catch {
                    debugPrint(error)
                }
            }
        }
    }
    var supportsExpose: Bool {
        guard let device = _videoInput?.device else { return false }
        let exposureModes: Set<AVCaptureDevice.ExposureMode> = [.locked, .autoExpose, .continuousAutoExposure]
        let supporting = exposureModes.map(device.isExposureModeSupported)
        let supports = supporting.reduce(false) { $0 || $1 }
        return supports
    }
    var barcodes: [AVMetadataObject] = []
    @objc dynamic var isRunning: Bool {
        _session?.isRunning ?? false
    }
    private let _operationQueue: OperationQueue
    private let metaQueue = DispatchQueue(label: "io.rthm.AVCam.metadata")
    private var metadataOutput: AVCaptureMetadataOutput?
    private var _applicationWillEnterForegroundNotificationObserver: Any? {
        didSet {
            guard let old = oldValue else { return }
            NotificationCenter.default.removeObserver(old)
        }
    }
    private var _previousSecondTimestamps = [Float64]()
    private var _sessionQueue = DispatchQueue(label: "io.rthm.sessionmanager.capture") {
        didSet {
            let capture = _sessionQueue
            _operationQueue.underlyingQueue = capture
        }
    }
    private var _startCaptureSessionOnEnteringForeground = false
    private var _session: AVCaptureSession?
    private var _audioConnection: AVCaptureConnection?
    private var _videoConnection: AVCaptureConnection?
    private var _videoDevice: AVCaptureDevice? = nil
    private var _videoInput: AVCaptureDeviceInput? = nil
    private var _pipelineRunningTask: UIBackgroundTaskIdentifier = .invalid
    override init() {
        _operationQueue = .init()
        _operationQueue.underlyingQueue = _sessionQueue
        exposureMode = .autoExpose
        focusMode = .autoFocus
        super.init()
    }
    func startRunning() {
        _sessionQueue.async(execute: _startRunning)
    }
    func stopRunning() {
        _sessionQueue.async(execute: _stopRunning)
    }
    func autoFocus(atPoint point: CGPoint) {
        guard let device = _videoInput?.device else { return }
        _autoFocus(device, atPoint: point)
    }
    func continuousFocus(atPoint point: CGPoint) {
        guard let device = _videoInput?.device else { return }
        _continuousFocus(device, atPoint: point)
    }
    func expose(atPoint point: CGPoint) {
        guard let device = _videoInput?.device else { return }
        _exposure(device, atPoint: point)
    }
    func setDelegate(_ delegate: SessionManagerDelegate, callback: DispatchQueue) {
        self.delegate = delegate
        if callback == _sessionQueue {
            return
        }
        _sessionQueue = callback
    }
    private func _applicationWillEnterForeground() {
        guard _startCaptureSessionOnEnteringForeground else {
            return
        }
        os_log("%@ %@ manually restarting session", NSStringFromClass(type(of: self)), #function)
        _startCaptureSessionOnEnteringForeground = false
        guard isRunning else {
            return
        }
        _session?.startRunning()
    }
    private func _autoFocus(_ device: AVCaptureDevice, atPoint point: CGPoint) {
        pointOfInterestWithFocusingMode(.autoFocus, forDevice: device, atPoint: point)
    }
    private func _exposure(_ device: AVCaptureDevice, atPoint point: CGPoint) {
        pointOfInterestWithExposureMode(.continuousAutoExposure, forDevice: device, atPoint: point)
    }
    private func _continuousFocus(_ device: AVCaptureDevice, atPoint point: CGPoint) {
        pointOfInterestWithFocusingMode(.continuousAutoFocus, forDevice: device, atPoint: point)
    }
    private func _startRunning() {
        _setupCaptureSession()
        willChangeValue(for: \.isRunning)
        _session?.startRunning()
        didChangeValue(for: \.isRunning)
        metadataOutput?.metadataObjectTypes = [.qr]
        
    }
    private func _stopRunning() {
        willChangeValue(for: \.isRunning)
        _session?.stopRunning()
        didChangeValue(for: \.isRunning)
        captureSessionDidStopRunning()
        teardownCaptureSession()
    }
    private func _setupCaptureSession() {
        guard _session == nil else {
            return
        }
        let session = AVCaptureSession()
        _session = session
        let center = NotificationCenter.default
        center.addObserver(forName: nil, object: session, queue: _operationQueue, using: captureSession)
        /// Video
        /// Video Device
        _videoDevice = AVCaptureDevice.default(for: .video)
        if let videoDevice = _videoDevice {
            do {
                let videoInput = try AVCaptureDeviceInput(device: videoDevice)
                _videoInput = videoInput
            } catch {
                debugPrint(error)
            }
        }
        /// Metadata output
        let metaOutput = AVCaptureMetadataOutput()
        metadataOutput = metaOutput
        metaOutput.setMetadataObjectsDelegate(self, queue: metaQueue)
        guard session.canAddOutput(metaOutput) else {
            return
        }
        session.addOutput(metaOutput)
    }
    private func applicationWillEnterForeground() {
        os_log("%@ %@ called", NSStringFromClass(type(of: self)), #function)
        _sessionQueue.async(execute: _applicationWillEnterForeground)
    }
    private func captureSession(notification: Notification) {
        switch notification.name {
        case .AVCaptureSessionWasInterrupted:
            os_log("Session interrupted")
            // AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableInBackground
            guard let userInfo = notification.userInfo else { break }
            guard let reason = userInfo[AVCaptureSessionInterruptionReasonKey] as? AVCaptureSession.InterruptionReason else { break }
            switch reason {
            case .videoDeviceNotAvailableInBackground:
                os_log("device not available in background")
                guard isRunning else {
                    break
                }
                _startCaptureSessionOnEnteringForeground = true
            default:
                captureSessionDidStopRunning()
            }
        case .AVCaptureSessionInterruptionEnded:
            os_log("session interruption ended")
        case .AVCaptureSessionRuntimeError:
            guard let userInfo = notification.userInfo else { break }
            guard let error = userInfo[AVCaptureSessionErrorKey] as? NSError else { break }
            switch error.code {
            case AVError.Code.mediaServicesWereReset.rawValue:
                os_log("media services were reset")
            default:
                handleNonRecoverableCaptureSessionRuntimeError(error)
            }
        case .AVCaptureSessionDidStartRunning:
            os_log("Did start running")
        case .AVCaptureSessionDidStopRunning:
            os_log("Did stop running")
        default:
            break
        }
    }
    private func captureSessionDidStopRunning() {
        teardownVideoPipeline()
    }
    private func handleNonRecoverableCaptureSessionRuntimeError(_ error: Error) {
        os_log("Fatal runtime error: %@, code %i", error.localizedDescription, (error as NSError).code)
        willChangeValue(for: \.isRunning)
        teardownCaptureSession()
        didChangeValue(for: \.isRunning)
        guard let d = delegate else { return }
        d.sessionManager(self, didStopRunningWithError: error)
    }
    private func teardownVideoPipeline() {
        videoPipelineDidFinishRunning()
    }
    private func teardownCaptureSession() {
        guard let session = _session else { return }
        let center: NotificationCenter = .default
        center.removeObserver(self, name: nil, object: session)
        _applicationWillEnterForegroundNotificationObserver = nil
        _session = nil
    }
    /// - MARK - Support point of interest based exposure and focus
    private func pointOfInterestWithExposureMode(_ mode: AVCaptureDevice.ExposureMode, forDevice device: AVCaptureDevice, atPoint point: CGPoint) {
        guard
            device.isExposurePointOfInterestSupported,
            device.isExposureModeSupported(mode)
            else {
                return
        }
        do {
            try device.lockForConfiguration()
            defer {
                device.unlockForConfiguration()
            }
            device.exposurePointOfInterest = point
            device.exposureMode = mode
        } catch {
            debugPrint(error)
        }
    }
    private func pointOfInterestWithFocusingMode(_ mode: AVCaptureDevice.FocusMode, forDevice device: AVCaptureDevice, atPoint point: CGPoint) {
        guard
            device.isFocusPointOfInterestSupported,
            device.isFocusModeSupported(mode)
            else {
                return
        }
        do {
            try device.lockForConfiguration()
            defer {
                device.unlockForConfiguration()
            }
            device.focusPointOfInterest = point
            device.focusMode = mode
        } catch {
            debugPrint(error)
        }
    }
    private func videoPipelineDidFinishRunning() {
        os_log("%@ %@ called", NSStringFromClass(type(of: self)), #function)
        if _pipelineRunningTask == .invalid {
            os_log("Background task is invalid, nothing to do")
            return
        }
        UIApplication.shared.endBackgroundTask(_pipelineRunningTask)
        _pipelineRunningTask = .invalid
    }
}

extension SessionManager: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        barcodes = metadataObjects
    }
}
