//
//  CameraSessionView.swift
//
//  Created by Hovik Melikyan on 26/05/2019.
//  Copyright © 2019 Hovik Melikyan. All rights reserved.
//


import UIKit
import AVFoundation


// TODO: implement session interruption observers


private let VIDEO_SESSION_PRESET = AVCaptureSession.Preset.hd1920x1080
private let VIDEO_CODEC_TYPE = AVVideoCodecType.hevc
private let AUDIO_FORMAT = Int(kAudioFormatMPEG4AAC)
private let AUDIO_SAMPLING_RATE = 44100.0
private let PHOTO_OUTPUT_CODEC_TYPE = AVVideoCodecType.jpeg
private let VIDEO_FILE_TYPE = AVFileType.mp4
// private let VIDEO_BUFFER_DIMENSIONS = CGSize(width: 1920, height: 1080)
private let VIDEO_BITRATE = 10 * 1024 * 1024
private let ORIENTATION = AVCaptureVideoOrientation.portrait


protocol CameraSessionViewDelegate: class {

	// Called after the session has been configured or reconfigured as a result of changes in input device, capture mode (photo vs. video). Can be used to e.g. enable UI controls that you should disable before making any changes in the configuration.
	func cameraSessionView(_ cameraSessionView: CameraSessionView, didCompleteConfigurationWithStatus status: CameraSessionView.Status)

	// Called when photo data is available after the call to capturePhoto(). Normally you would get the data via photo.fileDataRepresentation. Note that this method can be called multiple times in case both raw and another format was requested, or if operating in bracket mode (currently neither is supported by CameraSessionView)
	func cameraSessionView(_ cameraSessionView: CameraSessionView, didCapturePhoto photo: AVCapturePhoto?, error: Error?)

	// Optional; can be used to animate the capture, e.g. flash the screen or make sound
	func cameraSessionViewWillCapturePhoto(_ cameraSessionView: CameraSessionView)

	// Optional; called when all photo output formats have been delivered via cameraSessionView(_, didCapturePhoto:, error:)
	func cameraSessionView(_ cameraSessionView: CameraSessionView, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?)

	// Optional
	func cameraSessionViewDidStartRecording(_ cameraSessionView: CameraSessionView)

	// Does what it says; note that it is possible to have multiple recording processess finishing if background recording is enabled on the system; therefore it is recommended to have a unique/random temp file in each call to startRecording().
	func cameraSessionView(_ cameraSessionView: CameraSessionView, didFinishRecordingTo fileUrl: URL, error: Error?)

	// Optional; called in response to resumeInterruptedSession()
	func cameraSessionView(_ cameraSessionView: CameraSessionView, didResumeInterruptedSessionWithResult: Bool)
}


extension CameraSessionViewDelegate {
	// Default implementations of optional methods:
	func cameraSessionViewWillCapturePhoto(_ cameraSessionView: CameraSessionView) {}
	func cameraSessionView(_ cameraSessionView: CameraSessionView, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {}
	func cameraSessionViewDidStartRecording(_ cameraSessionView: CameraSessionView) {}
	func cameraSessionView(_ cameraSessionView: CameraSessionView, didResumeInterruptedSessionWithResult: Bool) {}
}


class CameraSessionView: UIView, AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

	enum Status: Equatable {
		case undefined
		case configured
		case notAuthorized
		case configurationFailed(message: String)
	}

	
	var isPhoto: Bool = true {
		didSet {
			if status == .configured && oldValue != isPhoto {
				didSwitchPhotoVideoMode()
			}
		}
	}

	var isVideo: Bool {
		get { return !isPhoto }
		set { isPhoto = !newValue }
	}

	var isFront: Bool = false {
		didSet {
			if status == .configured && oldValue != isFront {
				didSwitchCameraPosition()
			}
		}
	}

	var hasBackAndFront: Bool {
		return videoDeviceDiscoverySession.uniqueDevicePositions.count > 1
	}

	var isFlashEnabled: Bool = true // actually means automatic or off

	var hasFlash: Bool {
		return videoDeviceInput.device.isFlashAvailable
	}

	var isRecording: Bool {
		return videoWriter != nil
	}


	func initialize(delegate: CameraSessionViewDelegate, isPhoto: Bool, isFront: Bool) {
		precondition(status == .undefined)
		precondition(Thread.isMainThread)

		self.delegate = delegate
		self.isPhoto = isPhoto
		self.isFront = isFront

		if session == nil {
			session = AVCaptureSession()
			videoPreviewLayer.session = session
		}

		if queue == nil {
			queue = DispatchQueue(label: String(describing: self))
		}

		checkAuthorization() // runs on main thread, blocks the session thread if UI is involved

		queue.async {
			self.configureSession()
		}
	}


	deinit {
		removeAllObservers()
	}


	func capturePhoto() {
		queue.async {
			guard let photoOutput = self.photoOutput else {
				preconditionFailure()
			}
			let photoSettings = photoOutput.availablePhotoCodecTypes.contains(PHOTO_OUTPUT_CODEC_TYPE) ?
				AVCapturePhotoSettings(format: [AVVideoCodecKey: PHOTO_OUTPUT_CODEC_TYPE]) :
				AVCapturePhotoSettings()
			if self.videoDeviceInput.device.isFlashAvailable {
				photoSettings.flashMode = self.isFlashEnabled ? .auto : .off
			}
			if !photoSettings.__availablePreviewPhotoPixelFormatTypes.isEmpty {
				photoSettings.previewPhotoFormat = [kCVPixelBufferPixelFormatTypeKey as String: photoSettings.__availablePreviewPhotoPixelFormatTypes.first!]
			}
			photoOutput.capturePhoto(with: photoSettings, delegate: self)
		}
	}


	func startVideoRecording(toFileURL fileURL: URL) {
		queue.async {
			guard !self.isRecording else {
				return
			}
			precondition(self.videoWriter == nil && self.videoWriterInput == nil && self.audioWriterInput == nil)
			if UIDevice.current.isMultitaskingSupported {
				self.backgroundRecordingID = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
			}
			guard self.videoDeviceInput != nil && self.audioDeviceInput != nil else {
				return
			}
			self.videoWriter = try! AVAssetWriter(url: fileURL, fileType: VIDEO_FILE_TYPE)
		}
	}


	func stopVideoRecording() {
		queue.async {
			guard self.isRecording else {
				return
			}
			guard let videoWriter = self.videoWriter else {
				preconditionFailure()
			}
			if self.backgroundRecordingID != UIBackgroundTaskIdentifier.invalid {
				UIApplication.shared.endBackgroundTask(self.backgroundRecordingID)
				self.backgroundRecordingID = UIBackgroundTaskIdentifier.invalid
			}
			self.videoWriter = nil // buffer callback will start skipping, now we can shut everything down
			videoWriter.finishWriting {
				self.videoWriterInput = nil
				self.audioWriterInput = nil
				let error = videoWriter.status == .failed ? videoWriter.error : nil
				DispatchQueue.main.async {
					self.delegate?.cameraSessionView(self, didFinishRecordingTo: videoWriter.outputURL, error: error)
				}
			}
		}
	}


	func focus(with focusMode: AVCaptureDevice.FocusMode, exposureMode: AVCaptureDevice.ExposureMode, atPoint point: CGPoint,  monitorSubjectAreaChange: Bool) {
		let devicePoint = videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: point)
		queue.async {
			let device = self.videoDeviceInput.device
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
				print("CameraSessionView error: Could not lock device for configuration: \(error)")
			}
		}
	}


	func resumeInterruptedSession() {
		queue.async {
			/*
			The session might fail to start running, e.g., if a phone or FaceTime call is still
			using audio or video. A failure to start the session running will be communicated via
			a session runtime error notification. To avoid repeatedly failing to start the session
			running, we only try to restart the session running in the session runtime error handler
			if we aren't trying to resume the session running.
			*/
			self.session.startRunning()
			self.isSessionRunning = self.session.isRunning
			let result = self.isSessionRunning
			DispatchQueue.main.async {
				self.delegate?.cameraSessionView(self, didResumeInterruptedSessionWithResult: result)
			}
		}
	}


	override class var layerClass: AnyClass { return AVCaptureVideoPreviewLayer.self }
	private var videoPreviewLayer: AVCaptureVideoPreviewLayer { return layer as! AVCaptureVideoPreviewLayer }

	private var session: AVCaptureSession!
	private var queue: DispatchQueue!

	private weak var delegate: CameraSessionViewDelegate?
	private var status: Status = .undefined
	private var isSessionRunning = false

	private var videoDeviceInput: AVCaptureDeviceInput!
	private var audioDeviceInput: AVCaptureDeviceInput?
	private var photoOutput: AVCapturePhotoOutput?
	private var backgroundRecordingID: UIBackgroundTaskIdentifier = .invalid

	private var videoOutput: AVCaptureVideoDataOutput?
	private var audioOutput: AVCaptureAudioDataOutput?
	private var videoWriterInput: AVAssetWriterInput?
	private var audioWriterInput: AVAssetWriterInput?
	private var videoWriter: AVAssetWriter?


	// TODO: add .builtinTelelensCamera discovery
	private let videoDeviceDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInDualCamera, .builtInTrueDepthCamera], mediaType: .video, position: .unspecified)
	private let audioDeviceDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone], mediaType: AVMediaType.audio, position: .unspecified)


	// - - -  SETUP


	private func checkAuthorization() {
		switch AVCaptureDevice.authorizationStatus(for: .video) {
		case .authorized:
			break

		case .notDetermined:
			queue.suspend()
			AVCaptureDevice.requestAccess(for: .video, completionHandler: { granted in
				if !granted {
					self.status = .notAuthorized
				}
				self.queue.resume()
			})

		default:
			status = .notAuthorized
		}
	}


	private func didSwitchPhotoVideoMode() {
		queue.async {
			guard !self.isRecording else {
				return
			}
			self.configureSession()
		}
	}


	private func didSwitchCameraPosition() {
		queue.async {
			guard !self.isRecording else {
				return
			}
			if let videoDeviceInput = self.videoDeviceInput {
				self.removeDeviceInputObservers()
				self.session.removeInput(videoDeviceInput)
				self.videoDeviceInput = nil
			}
			if let videoOutput = self.videoOutput { // it's important to reset the videoOutput too, for the orientation thing to work properly
				self.session.removeOutput(videoOutput)
				self.videoOutput = nil
			}
			self.configureSession()
		}
	}


	private func configureSession() {
		precondition(!Thread.isMainThread)

		guard status == .undefined || status == .configured else {
			return
		}

		session.beginConfiguration()

		session.sessionPreset = isPhoto ? .photo : VIDEO_SESSION_PRESET

		configureVideoInput()
		configureAudioInput()
		configurePhotoOutput()
		configureVideoOutput()
		configureAudioOutput()

		session.commitConfiguration()

		if status == .undefined {
			addObservers()
		}

		status = .configured
		session.startRunning()
		isSessionRunning = self.session.isRunning

		DispatchQueue.main.async {
			self.delegate?.cameraSessionView(self, didCompleteConfigurationWithStatus: self.status)
		}
	}


	private func configureVideoInput() {
		precondition(!Thread.isMainThread)
		if videoDeviceInput == nil {
			do {
				if let videoDevice = findMatchingVideoDevice() {
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


	private func findMatchingVideoDevice() -> AVCaptureDevice? {
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
		if isVideo && audioDeviceInput == nil {
			do {
				let audioDevice = AVCaptureDevice.default(for: .audio)
				let audioDeviceInput = try AVCaptureDeviceInput(device: audioDevice!)
				if session.canAddInput(audioDeviceInput) {
					session.addInput(audioDeviceInput)
					self.audioDeviceInput = audioDeviceInput
				} else {
					print("CameraSessionView error: Could not add audio device input to the session")
				}
			} catch {
				print("CameraSessionView error: Could not create audio device input: \(error)")
			}
		}
		else if !isVideo, let audioDeviceInput = audioDeviceInput {
			session.removeInput(audioDeviceInput)
			self.audioDeviceInput = nil
		}
	}


	private func configureVideoOutput() {
		precondition(!Thread.isMainThread)
		if isVideo && videoOutput == nil {
			let videoOutput = AVCaptureVideoDataOutput()
			if session.canAddOutput(videoOutput) {
				session.addOutput(videoOutput)
				if let connection = videoOutput.connection(with: .video) {
					connection.videoOrientation = ORIENTATION
					if connection.isVideoStabilizationSupported {
						connection.preferredVideoStabilizationMode = .auto
					}
				}
				else {
					print("CameraSessionView error: no video output connection")
				}
				// kCVPixelFormatType_420YpCbCr8BiPlanarFullRange if supported
				videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as [String : Any]
				videoOutput.alwaysDiscardsLateVideoFrames = true
				videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue.global(qos: .default))
				self.videoOutput = videoOutput
			}
		}
		else if !isVideo, let videoOutput = videoOutput {
			session.removeOutput(videoOutput)
			self.videoOutput = nil
		}
	}


	private func configureAudioOutput() {
		precondition(!Thread.isMainThread)
		if isVideo && audioOutput == nil {
			let audioOutput = AVCaptureAudioDataOutput()
			if session.canAddOutput(audioOutput) {
				audioOutput.setSampleBufferDelegate(self, queue: DispatchQueue.global(qos: .default))
				session.addOutput(audioOutput)
				self.audioOutput = audioOutput
			}
		}
		else if !isVideo, let audioOutput = audioOutput {
			session.removeOutput(audioOutput)
			self.audioOutput = nil
		}
	}


	private func prepareWriterInputs(forWidth width: Int, height: Int) {
		precondition(!Thread.isMainThread)
		precondition(ORIENTATION == .portrait)
		guard let videoWriter = videoWriter else {
			preconditionFailure()
		}

		let videoSettings = [
				AVVideoCodecKey: VIDEO_CODEC_TYPE,
				AVVideoWidthKey: width,
				AVVideoHeightKey: height,
				AVVideoScalingModeKey : AVVideoScalingModeResizeAspectFill,
				AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: VIDEO_BITRATE]
			] as [String : Any]
		let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
		videoWriterInput.expectsMediaDataInRealTime = true
		if width > height { // assumes portrait mode: fix the orientation
			videoWriterInput.transform = CGAffineTransform(rotationAngle: CGFloat.pi / 2)
		}
		videoWriter.add(videoWriterInput)

		let audioSettings = [
				AVFormatIDKey: AUDIO_FORMAT,
				AVSampleRateKey: AUDIO_SAMPLING_RATE,
				AVNumberOfChannelsKey: 1,
				AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
			] as [String : Any]
		let audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
		audioWriterInput.expectsMediaDataInRealTime = true
		videoWriter.add(audioWriterInput)

		self.videoWriterInput = videoWriterInput
		self.audioWriterInput = audioWriterInput
	}


	private func configurePhotoOutput() {
		precondition(!Thread.isMainThread)
		if isPhoto && photoOutput == nil {
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
		else if !isPhoto, let photoOutput = photoOutput {
			session.removeOutput(photoOutput)
			self.photoOutput = nil
		}
	}


	private func configurationFailed(message: String) {
		status = .configurationFailed(message: message)
		session.commitConfiguration()
		DispatchQueue.main.async {
			self.delegate?.cameraSessionView(self, didCompleteConfigurationWithStatus: self.status)
		}
	}


	// - - -  CAPTURE/RECORDING DELEGATES

	func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
		DispatchQueue.main.async {
			self.delegate?.cameraSessionViewWillCapturePhoto(self)
		}
	}


	func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
		DispatchQueue.main.async {
			self.delegate?.cameraSessionView(self, didCapturePhoto: photo, error: error)
		}
	}


	func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
		DispatchQueue.main.async {
			self.delegate?.cameraSessionView(self, didFinishCaptureFor: resolvedSettings, error: error)
		}
	}


	func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
		// TODO: processing delegates
		queue.async {

			// 1. If we are not recording, just skip this cycle
			guard let videoWriter = self.videoWriter else {
				return
			}

			// 2. Recording enabled but the file writer hasn't started writing yet:
			if videoWriter.status == .unknown {
				precondition(self.videoWriterInput == nil && self.audioWriterInput == nil)
				if let pixelBuf = CMSampleBufferGetImageBuffer(sampleBuffer) {
					let width = CVPixelBufferGetWidth(pixelBuf)
					let height = CVPixelBufferGetHeight(pixelBuf)
					self.prepareWriterInputs(forWidth: width, height: height)
					videoWriter.startWriting()
					videoWriter.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
					DispatchQueue.main.async {
						print("Video recording started with \(width):\(height)")
						self.delegate?.cameraSessionViewDidStartRecording(self)
					}
				}
			}

			// 3. Guard against failed initialization
			guard let videoWriterInput = self.videoWriterInput, let audioWriterInput = self.audioWriterInput, videoWriter.status == .writing else {
				return
			}

			// 4. Send the buffer to the writer chain
			switch output {
			case self.videoOutput:
				if videoWriterInput.isReadyForMoreMediaData {
					videoWriterInput.append(sampleBuffer)
				}
			case self.audioOutput:
				if audioWriterInput.isReadyForMoreMediaData {
					audioWriterInput.append(sampleBuffer)
				}
			default:
				break
			}
		}
	}


	// - - -  OBSERVERS

	private var keyValueObservations = [NSKeyValueObservation]()

	private func addObservers() {
//		let keyValueObservation = session.observe(\.isRunning, options: .new) { _, change in
//			if change.newValue ?? false {
//				DispatchQueue.main.async {
//					self.delegate?.cameraSessionViewSessionStarted(self)
//				}
//			}
//		}
//		keyValueObservations.append(keyValueObservation)

		// NotificationCenter.default.addObserver(self, selector: #selector(sessionRuntimeError), name: .AVCaptureSessionRuntimeError, object: session)

		/*
		A session can only run when the app is full screen. It will be interrupted
		in a multi-app layout, introduced in iOS 9, see also the documentation of
		AVCaptureSessionInterruptionReason. Add observers to handle these session
		interruptions and show a preview is paused message. See the documentation
		of AVCaptureSessionWasInterruptedNotification for other interruption reasons.
		*/
		// NotificationCenter.default.addObserver(self, selector: #selector(sessionWasInterrupted), name: .AVCaptureSessionWasInterrupted, object: session)
		// NotificationCenter.default.addObserver(self, selector: #selector(sessionInterruptionEnded), name: AVCaptureSessionInterruptionEnded, object: session)
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
		for keyValueObservation in keyValueObservations {
			keyValueObservation.invalidate()
		}
		keyValueObservations.removeAll()
	}


	@objc
	func subjectAreaDidChange(notification: NSNotification) {
		let point = CGPoint(x: bounds.midX, y: bounds.midY)
		focus(with: .continuousAutoFocus, exposureMode: .continuousAutoExposure, atPoint: point, monitorSubjectAreaChange: false)
	}


/*
	/// - Tag: HandleRuntimeError
	@objc
	func sessionRuntimeError(notification: NSNotification) {
		guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else { return }

		print("CameraSessionView error: Capture session runtime error: \(error)")
		// If media services were reset, and the last start succeeded, restart the session.
		if error.code == .mediaServicesWereReset {
			queue.async {
				if self.session.isSessionRunning {
					self.session.startRunning()
					self.isSessionRunning = self.session.isRunning
				} else {
					DispatchQueue.main.async {
						self.resumeButton.isHidden = false
					}
				}
			}
		} else {
			resumeButton.isHidden = false
		}
	}


	/// - Tag: HandleInterruption
	@objc
	func sessionWasInterrupted(notification: NSNotification) {
		/*
		In some scenarios we want to enable the user to resume the session running.
		For example, if music playback is initiated via control center while
		using CameraSessionView, then the user can let CameraSessionView resume
		the session running, which will stop music playback. Note that stopping
		music playback in control center will not automatically resume the session
		running. Also note that it is not always possible to resume, see `resumeInterruptedSession(_:)`.
		*/
		if let userInfoValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as AnyObject?,
			let reasonIntegerValue = userInfoValue.integerValue,
			let reason = AVCaptureSession.InterruptionReason(rawValue: reasonIntegerValue) {
			print("CameraSessionView error: Capture session was interrupted with reason \(reason)")

			var showResumeButton = false
			if reason == .audioDeviceInUseByAnotherClient || reason == .videoDeviceInUseByAnotherClient {
				showResumeButton = true
			} else if reason == .videoDeviceNotAvailableWithMultipleForegroundApps {
				// Fade-in a label to inform the user that the camera is unavailable.
				cameraUnavailableLabel.alpha = 0
				cameraUnavailableLabel.isHidden = false
				UIView.animate(withDuration: 0.25) {
					self.cameraUnavailableLabel.alpha = 1
				}
			} else if reason == .videoDeviceNotAvailableDueToSystemPressure {
				print("CameraSessionView error: Session stopped running due to shutdown system pressure level.")
			}
			if showResumeButton {
				// Fade-in a button to enable the user to try to resume the session running.
				resumeButton.alpha = 0
				resumeButton.isHidden = false
				UIView.animate(withDuration: 0.25) {
					self.resumeButton.alpha = 1
				}
			}
		}
	}

	@objc
	func sessionInterruptionEnded(notification: NSNotification) {
		print("CameraSessionView error: Capture session interruption ended")

		if !resumeButton.isHidden {
			UIView.animate(withDuration: 0.25,
						   animations: {
							self.resumeButton.alpha = 0
			}, completion: { _ in
				self.resumeButton.isHidden = true
			})
		}
		if !cameraUnavailableLabel.isHidden {
			UIView.animate(withDuration: 0.25,
						   animations: {
							self.cameraUnavailableLabel.alpha = 0
			}, completion: { _ in
				self.cameraUnavailableLabel.isHidden = true
			}
			)
		}
	}
*/
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
