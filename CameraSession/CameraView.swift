//
//  CameraView.swift
//
//  Created by Hovik Melikyan on 26/05/2019.
//  Copyright © 2019 Hovik Melikyan. All rights reserved.
//
//  Version 1.2 (2021-10-10)
//


import UIKit
import AVFoundation


private let VIDEO_CODEC_TYPE = AVVideoCodecType.hevc
private let PHOTO_OUTPUT_CODEC_TYPE = AVVideoCodecType.jpeg
private let ORIENTATION = AVCaptureVideoOrientation.portrait


public protocol CameraViewDelegate: AnyObject {

	// Called after the session has been configured or reconfigured as a result of changes in input device, capture mode (photo vs. video). Can be used to e.g. enable UI controls that you should disable before making any changes in the configuration.
	func cameraView(_ cameraView: CameraView, didCompleteConfigurationWithStatus status: CameraView.Status)

	// Optional. Called in response to assigning zoomLevel, which at this point will hold the real zoom level. Same for the torch.
	func cameraViewDidChangeZoomLevel(_ cameraView: CameraView)
	func cameraViewDidSwitchTorch(_ cameraView: CameraView)

	// Called when photo data is available after the call to capturePhoto(). Normally you would get the data via photo.fileDataRepresentation. Note that this method can be called multiple times in case both raw and another format was requested, or if operating in bracket mode (currently neither is supported by CameraView)
	func cameraView(_ cameraView: CameraView, didCapturePhoto photo: AVCapturePhoto?, error: Error?)

	// Optional; can be used to animate the capture, e.g. flash the screen or make sound
	func cameraViewWillCapturePhoto(_ cameraView: CameraView)

	// Optional; called when all photo output formats have been delivered via CameraView(_, didCapturePhoto:, error:)
	func cameraView(_ cameraView: CameraView, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?)

	// Optional
	func cameraViewDidStartRecording(_ cameraView: CameraView)

	// Does what it says; note that it is possible to have multiple recording processess finishing if background recording is enabled on the system; therefore it is recommended to have a unique/random temp file in each call to startRecording().
	func cameraView(_ cameraView: CameraView, didFinishRecordingTo fileUrl: URL, error: Error?)

	// Optional; called on runtime error or interruption. The UI can show a button that allows to resume the sesion manually using the resumeSession() call
	func cameraView(_ cameraView: CameraView, wasInterruptedWithError: Error?)
	func cameraView(_ cameraView: CameraView, wasInterruptedWithReason: AVCaptureSession.InterruptionReason)

	// Optional; called in response to resumeInterruptedSession()
	func cameraView(_ cameraView: CameraView, didResumeInterruptedSessionWithResult: Bool)
}


public extension CameraViewDelegate {
	// Default implementations of optional methods:
	func cameraViewDidChangeZoomLevel(_ cameraView: CameraView) {}
	func cameraViewDidSwitchTorch(_ cameraView: CameraView) {}
	func cameraViewWillCapturePhoto(_ cameraView: CameraView) {}
	func cameraView(_ cameraView: CameraView, didCapturePhoto photo: AVCapturePhoto?, error: Error?) {}
	func cameraView(_ cameraView: CameraView, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {}
	func cameraViewDidStartRecording(_ cameraView: CameraView) {}
	func cameraView(_ cameraView: CameraView, didFinishRecordingTo fileUrl: URL, error: Error?) {}
	func cameraView(_ cameraView: CameraView, wasInterruptedWithError: Error?) {}
	func cameraView(_ cameraView: CameraView, wasInterruptedWithReason: AVCaptureSession.InterruptionReason) {}
	func cameraView(_ cameraView: CameraView, didResumeInterruptedSessionWithResult: Bool) {}
}



public enum CameraViewError: LocalizedError {
	case sessionNotRunning

	public var errorDescription: String? { "Camera session not running" }
}



// MARK: - Camera session view main class


open class CameraView: UIView, AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate {

	public enum Status: Equatable {
		case undefined
		case configured
		case notAuthorized
		case configurationFailed(message: String)
	}

	public enum OutputMode: Equatable {
		case photo
		case video
		case photoAndVideo
		// TODO: add QR code mode

		public var isVideo: Bool { self != .photo }
		public var isPhoto: Bool { self != .video }
	}

	open private(set) var status: Status = .undefined

	open var outputMode: OutputMode = .photo {
		didSet {
			if status == .configured && oldValue != outputMode {
				didSwitchPhotoVideoMode()
			}
		}
	}

	open private(set) var sessionPreset: AVCaptureSession.Preset = .high


	open var hasBackAndFront: Bool {
		videoDeviceDiscoverySession.uniqueDevicePositions.count > 1
	}

	open var isFront: Bool {
		get { videoDeviceInput?.device.position == .front }
		set {
			if newValue != isFront, hasBackAndFront, !isRecording {
				queue.async {
					self.trySwitchCameraPosition(newValue)
				}
			}
		}
	}


	open var hasFlash: Bool { videoDeviceInput?.device.isFlashAvailable ?? false }

	open var isFlashEnabled: Bool = true // actually means automatic or off


	open var hasZoom: Bool { videoDeviceInput?.device.minAvailableVideoZoomFactor != videoDeviceInput?.device.maxAvailableVideoZoomFactor }

	open var zoomLevel: CGFloat {
		get { videoDeviceInput?.device.videoZoomFactor ?? 1 }
		set {
			if newValue != zoomLevel, hasZoom {
				queue.async {
					self.trySetZoomLevel(newValue)
				}
			}
		}
	}


	open var hasTorch: Bool { videoDeviceInput?.device.isTorchAvailable ?? false }

	open var isTorchOn: Bool {
		get { videoDeviceInput?.device.torchMode == .on }
		set {
			if newValue != isTorchOn, hasTorch {
				queue.async {
					self.trySwitchTorch(newValue)
				}
			}
		}
	}


	open var maxRecordedDuration: TimeInterval = 30

	open var isRecording: Bool { videoOutput?.isRecording ?? false }


	open func initialize(delegate: CameraViewDelegate, outputMode: OutputMode, isFront: Bool, sessionPreset: AVCaptureSession.Preset = .high, maxRecordedDuration: TimeInterval = 30) {
		precondition(status == .undefined)
		precondition(Thread.isMainThread)

		self.delegate = delegate
		self.outputMode = outputMode
		self.sessionPreset = sessionPreset
		self.maxRecordedDuration = maxRecordedDuration

		if videoPreviewLayer.session == nil {
			videoPreviewLayer.session = session
			videoPreviewLayer.videoGravity = .resizeAspectFill
		}

		checkAuthorization(forAudio: false) { [self] videoGranted in
			if videoGranted && outputMode.isVideo {
				checkAuthorization(forAudio: true) { audioGranted in
					queue.async {
						configureSession(isFront: isFront)
					}
				}
			}
			else {
				queue.async {
					configureSession(isFront: isFront)
				}
			}
		}
	}


	deinit {
		self.session.stopRunning()
		removeAllObservers()
		#if DEBUG
		print("CameraSession: deinit")
		#endif
	}


	public func resumeSession(completion: (() -> Void)? = nil) {
		queue.async {
			// TODO: torch should be re-enabled here
			self.session.startRunning()
			DispatchQueue.main.async {
				completion?()
			}
		}
	}


	public func pauseSession(completion: (() -> Void)? = nil) {
		queue.async {
			self.session.stopRunning()
			DispatchQueue.main.async {
				completion?()
			}
		}
	}


	open func capturePhoto() {
		queue.async {
			guard self.session.isRunning, let photoOutput = self.photoOutput, let videoDeviceInput = self.videoDeviceInput else {
				DispatchQueue.main.async {
					self.delegate?.cameraView(self, didCapturePhoto: nil, error: CameraViewError.sessionNotRunning)
				}
				return
			}
			let photoSettings = photoOutput.availablePhotoCodecTypes.contains(PHOTO_OUTPUT_CODEC_TYPE) ?
				AVCapturePhotoSettings(format: [AVVideoCodecKey: PHOTO_OUTPUT_CODEC_TYPE]) :
				AVCapturePhotoSettings()
			if videoDeviceInput.device.isFlashAvailable {
				photoSettings.flashMode = self.isFlashEnabled ? .auto : .off
			}
			if !photoSettings.__availablePreviewPhotoPixelFormatTypes.isEmpty {
				photoSettings.previewPhotoFormat = [kCVPixelBufferPixelFormatTypeKey as String: photoSettings.__availablePreviewPhotoPixelFormatTypes.first!]
			}
			photoOutput.capturePhoto(with: photoSettings, delegate: self)
		}
	}


	open func startVideoRecording(toFileURL fileURL: URL) {
		queue.async {
			guard self.session.isRunning, let videoOutput = self.videoOutput else {
				DispatchQueue.main.async {
					self.delegate?.cameraView(self, didFinishRecordingTo: fileURL, error: CameraViewError.sessionNotRunning)
				}
				return
			}
			guard !self.isRecording else {
				return
			}
			if UIDevice.current.isMultitaskingSupported {
				self.backgroundRecordingID = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
			}
			videoOutput.maxRecordedDuration = CMTime(seconds: self.maxRecordedDuration, preferredTimescale: 1)
			videoOutput.startRecording(to: fileURL, recordingDelegate: self)
		}
	}


	open func stopVideoRecording() {
		queue.async {
			guard let videoOutput = self.videoOutput else {
				return
			}
			if self.backgroundRecordingID != UIBackgroundTaskIdentifier.invalid {
				UIApplication.shared.endBackgroundTask(self.backgroundRecordingID)
				self.backgroundRecordingID = UIBackgroundTaskIdentifier.invalid
			}
			videoOutput.stopRecording()
		}
	}


	open func focus(with focusMode: AVCaptureDevice.FocusMode, exposureMode: AVCaptureDevice.ExposureMode, atPoint point: CGPoint,  monitorSubjectAreaChange: Bool) {
		let devicePoint = videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: point)
		queue.async {
			guard let device = self.videoDeviceInput?.device else { return }
			do {
				try device.lockForConfiguration()
				if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(focusMode) {
					device.focusPointOfInterest = devicePoint
					device.focusMode = focusMode
				}
				if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(exposureMode) {
					device.exposurePointOfInterest = devicePoint
					device.exposureMode = exposureMode
				}
				device.isSubjectAreaChangeMonitoringEnabled = monitorSubjectAreaChange
				device.unlockForConfiguration()
			} catch {
				print("CameraView error: Could not lock device for configuration: \(error)")
			}
		}
	}


	public func resumeInterruptedSession() {
		queue.async {
			self.session.startRunning()
			let result = self.session.isRunning
			DispatchQueue.main.async {
				self.delegate?.cameraView(self, didResumeInterruptedSessionWithResult: result)
			}
		}
	}


	open override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
	private var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

	private let session = AVCaptureSession()
	private let queue = DispatchQueue(label: String(describing: self))

	private weak var delegate: CameraViewDelegate?

	private var videoDeviceInput: AVCaptureDeviceInput?
	private var audioDeviceInput: AVCaptureDeviceInput?
	private var photoOutput: AVCapturePhotoOutput?
	private var videoOutput: AVCaptureMovieFileOutput?
	private var backgroundRecordingID: UIBackgroundTaskIdentifier = .invalid

	private let videoDeviceDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInDualCamera, .builtInTelephotoCamera], mediaType: .video, position: .unspecified)
	private let audioDeviceDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone], mediaType: AVMediaType.audio, position: .unspecified)


	// - - -  SETUP


	private func checkAuthorization(forAudio: Bool, completion: @escaping (Bool) -> Void) {
		switch AVCaptureDevice.authorizationStatus(for: forAudio ? .audio : .video) {
			case .authorized:
				completion(true)

			case .notDetermined:
				queue.suspend()
				AVCaptureDevice.requestAccess(for: forAudio ? .audio : .video, completionHandler: { granted in
					if !granted {
						self.status = .notAuthorized
					}
					self.queue.resume()
					completion(granted)
				})

			default:
				completion(false)
				status = .notAuthorized
		}
	}


	private func didSwitchPhotoVideoMode() {
		queue.async {
			guard !self.isRecording else { return }
			self.configureSession(isFront: self.isFront)
		}
	}


	private func trySwitchCameraPosition(_ isFront: Bool) {
		precondition(!Thread.isMainThread)
		guard !self.isRecording else { return }
		self.session.stopRunning()
		if let videoDeviceInput = self.videoDeviceInput {
			self.removeDeviceInputObservers()
			self.session.removeInput(videoDeviceInput)
			self.videoDeviceInput = nil
		}
		if let videoOutput = self.videoOutput { // it's important to reset the videoOutput too, for the orientation thing to work properly
			self.session.removeOutput(videoOutput)
			self.videoOutput = nil
		}
		self.configureSession(isFront: isFront)
	}


	private func configureSession(isFront: Bool) {
		precondition(!Thread.isMainThread)

		guard status == .undefined || status == .configured else { return }

		session.beginConfiguration()

		session.sessionPreset = sessionPreset

		configureVideoInput(isFront: isFront)
		configureAudioInput()
		configurePhotoOutput()
		configureVideoOutput()

		session.commitConfiguration()

		if status == .undefined {
			addObservers()
		}

		status = .configured
		session.startRunning()

		DispatchQueue.main.async {
			self.delegate?.cameraView(self, didCompleteConfigurationWithStatus: self.status)
		}
	}


	private func configureVideoInput(isFront: Bool) {
		precondition(!Thread.isMainThread)
		if videoDeviceInput == nil {
			do {
				if let videoDevice = findMatchingVideoDevice(isFront: isFront) {
					let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
					if session.canAddInput(videoDeviceInput) {
						session.addInput(videoDeviceInput)
						self.videoDeviceInput = videoDeviceInput
						addDeviceInputObservers()
						DispatchQueue.main.async {
							self.videoPreviewLayer.connection?.videoOrientation = ORIENTATION
						}
					} else {
						configurationFailed(message: "Couldn't add video device input to the session.")
						return
					}
				}
				else {
					configurationFailed(message: "No cameras found on this device. Is this a rotary phone or what?")
				}
			} catch {
				configurationFailed(message: "Couldn't create video device input: \(error)")
				return
			}
		}
	}


	private func trySetZoomLevel(_ zoomLevel: CGFloat) {
		precondition(!Thread.isMainThread)
		guard let videoDeviceInput = videoDeviceInput, hasZoom else { return }
		do {
			try videoDeviceInput.device.lockForConfiguration()
			videoDeviceInput.device.videoZoomFactor = zoomLevel
			videoDeviceInput.device.unlockForConfiguration()
			DispatchQueue.main.async {
				self.delegate?.cameraViewDidChangeZoomLevel(self)
			}
		} catch let error {
			print("CameraView error: \(error)")
		}
	}


	private func trySwitchTorch(_ on: Bool) {
		precondition(!Thread.isMainThread)
		guard let videoDeviceInput = videoDeviceInput, hasTorch else { return }
		do {
			try videoDeviceInput.device.lockForConfiguration()
			videoDeviceInput.device.torchMode = on ? .on : .off
			videoDeviceInput.device.unlockForConfiguration()
			DispatchQueue.main.async {
				self.delegate?.cameraViewDidSwitchTorch(self)
			}
		} catch let error {
			print("CameraView error: \(error)")
		}
	}


	private func findMatchingVideoDevice(isFront: Bool) -> AVCaptureDevice? {
		let type: AVCaptureDevice.DeviceType = isFront ? .builtInWideAngleCamera : .builtInDualCamera
		let position: AVCaptureDevice.Position = isFront ? .front : .back

		// First, look for a device with both the preferred position and device type
		if let device = videoDeviceDiscoverySession.devices.first(where: { $0.deviceType == type && $0.position == position }) {
			return device
		}

		// Otherwise, look for a device with only the preferred position
		if let device = videoDeviceDiscoverySession.devices.first(where: { $0.position == position }) {
			return device
		}

		// Or else, return just any device
		return videoDeviceDiscoverySession.devices.first
	}


	private func configureAudioInput() {
		precondition(!Thread.isMainThread)
		if !outputMode.isVideo, let audioDeviceInput = audioDeviceInput {
			session.removeInput(audioDeviceInput)
			self.audioDeviceInput = nil
		}
		if outputMode.isVideo, audioDeviceInput == nil, let audioDevice = AVCaptureDevice.default(for: .audio) {
			do {
				let audioDeviceInput = try AVCaptureDeviceInput(device: audioDevice)
				if session.canAddInput(audioDeviceInput) {
					session.addInput(audioDeviceInput)
					self.audioDeviceInput = audioDeviceInput
				} else {
					print("CameraView error: Could not add audio device input to the session")
				}
			} catch {
				print("CameraView error: Could not create audio device input: \(error)")
			}
		}
	}


	private func configureVideoOutput() {
		precondition(!Thread.isMainThread)
		if !outputMode.isVideo, let videoOutput = videoOutput {
			session.removeOutput(videoOutput)
			self.videoOutput = nil
		}
		if outputMode.isVideo && videoOutput == nil {
			let videoOutput = AVCaptureMovieFileOutput()
			if session.canAddOutput(videoOutput) {
				session.addOutput(videoOutput)
				if let connection = videoOutput.connection(with: .video) {
					connection.videoOrientation = ORIENTATION
					if connection.isVideoStabilizationSupported {
						connection.preferredVideoStabilizationMode = .auto
					}
					if connection.isVideoMirroringSupported {
						connection.isVideoMirrored = isFront
					}
					if videoOutput.availableVideoCodecTypes.contains(VIDEO_CODEC_TYPE) {
						videoOutput.setOutputSettings([AVVideoCodecKey: VIDEO_CODEC_TYPE], for: connection)
					}
				}
				else {
					print("CameraView error: no video output connection")
				}
				self.videoOutput = videoOutput
			}
		}
	}


	private func configurePhotoOutput() {
		precondition(!Thread.isMainThread)
		if !outputMode.isPhoto, let photoOutput = photoOutput {
			session.removeOutput(photoOutput)
			self.photoOutput = nil
		}
		if outputMode.isPhoto && photoOutput == nil {
			let photoOutput = AVCapturePhotoOutput()
			if session.canAddOutput(photoOutput) {
				session.addOutput(photoOutput)
				photoOutput.isHighResolutionCaptureEnabled = true
				if let connection = photoOutput.connection(with: .video) {
					connection.videoOrientation = ORIENTATION
				}
				self.photoOutput = photoOutput
			} else {
				configurationFailed(message: "Could not add photo output to the session")
				return
			}
		}
	}


	private func configurationFailed(message: String) {
		status = .configurationFailed(message: message)
		session.commitConfiguration()
		DispatchQueue.main.async {
			self.delegate?.cameraView(self, didCompleteConfigurationWithStatus: self.status)
		}
	}


	// - - -  CAPTURE/RECORDING DELEGATES

	public func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
		DispatchQueue.main.async {
			self.delegate?.cameraViewWillCapturePhoto(self)
		}
	}


	public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
		DispatchQueue.main.async {
			self.delegate?.cameraView(self, didCapturePhoto: photo, error: error)
		}
	}


	public func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
		DispatchQueue.main.async {
			self.delegate?.cameraView(self, didFinishCaptureFor: resolvedSettings, error: error)
		}
	}


	public func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
		DispatchQueue.main.async {
			self.delegate?.cameraViewDidStartRecording(self)
		}
	}


	public func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
		if backgroundRecordingID != UIBackgroundTaskIdentifier.invalid {
			UIApplication.shared.endBackgroundTask(backgroundRecordingID)
			backgroundRecordingID = UIBackgroundTaskIdentifier.invalid
		}
		DispatchQueue.main.async {
			self.delegate?.cameraView(self, didFinishRecordingTo: outputFileURL, error: error)
		}
	}


	// - - -  OBSERVERS

	private func addObservers() {
		NotificationCenter.default.addObserver(self, selector: #selector(sessionRuntimeError), name: .AVCaptureSessionRuntimeError, object: session)
		NotificationCenter.default.addObserver(self, selector: #selector(sessionWasInterrupted), name: .AVCaptureSessionWasInterrupted, object: session)
		NotificationCenter.default.addObserver(self, selector: #selector(sessionInterruptionEnded), name: .AVCaptureSessionInterruptionEnded, object: session)
	}


	private func addDeviceInputObservers() {
		if let device = videoDeviceInput?.device {
			NotificationCenter.default.addObserver(self, selector: #selector(subjectAreaDidChange), name: .AVCaptureDeviceSubjectAreaDidChange, object: device)
		}
	}


	private func removeDeviceInputObservers() {
		if let device = videoDeviceInput?.device {
			NotificationCenter.default.removeObserver(self, name: .AVCaptureDeviceSubjectAreaDidChange, object: device)
		}
	}


	private func removeAllObservers() {
		NotificationCenter.default.removeObserver(self)
	}


	@objc func subjectAreaDidChange(notification: NSNotification) {
		let point = CGPoint(x: bounds.midX, y: bounds.midY)
		focus(with: .continuousAutoFocus, exposureMode: .continuousAutoExposure, atPoint: point, monitorSubjectAreaChange: false)
	}


	@objc func sessionRuntimeError(notification: NSNotification) {
		guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else { return }
		delegate?.cameraView(self, wasInterruptedWithError: error)
	}


	@objc func sessionWasInterrupted(notification: NSNotification) {
		if let userInfoValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as AnyObject?,
		   let reasonIntegerValue = userInfoValue.integerValue,
		   let reason = AVCaptureSession.InterruptionReason(rawValue: reasonIntegerValue) {
			print("CameraView error: Capture session was interrupted with reason \(reason.rawValue)")
			delegate?.cameraView(self, wasInterruptedWithReason: reason)
		}
	}


	@objc func sessionInterruptionEnded(notification: NSNotification) {
		print("CameraView error: Capture session interruption ended")
		delegate?.cameraView(self, didResumeInterruptedSessionWithResult: true)
	}
}


private extension AVCaptureDevice.DiscoverySession {
	var uniqueDevicePositions: [AVCaptureDevice.Position] {
		var result: [AVCaptureDevice.Position] = []
		for device in devices {
			if !result.contains(device.position) {
				result.append(device.position)
			}
		}
		return result
	}
}
