//
//  CameraSessionView.swift
//
//  Created by Hovik Melikyan on 26/05/2019.
//  Copyright © 2019 Hovik Melikyan. All rights reserved.
//


import UIKit
import AVFoundation


private let BEST_VIDEO_CODEC_TYPE = AVVideoCodecType.hevc
private let FALLBACK_VIDEO_CODE_TYPE = AVVideoCodecType.h264 // older devices
private let AUDIO_FORMAT = Int(kAudioFormatMPEG4AAC)
private let AUDIO_SAMPLING_RATE = 44100.0
private let PHOTO_OUTPUT_CODEC_TYPE = AVVideoCodecType.jpeg
private let VIDEO_FILE_TYPE = AVFileType.mp4
private let VIDEO_BUFFER_DIMENSIONS = CGSize(width: 1080, height: 1920)
private let VIDEO_BITRATE = 10 * 1024 * 1024
private let ORIENTATION = AVCaptureVideoOrientation.portrait


protocol CameraSessionViewDelegate: class {

	// Called after the session has been configured or reconfigured as a result of changes in input device, capture mode (photo vs. video). Can be used to e.g. enable UI controls that you should disable before making any changes in the configuration.
	func cameraSessionView(_ cameraSessionView: CameraSessionView, didCompleteConfigurationWithStatus status: CameraSessionView.Status)

	// Optional. Called in response to assigning zoomLevel, which at this point will hold the real zoom level. Same for the torch.
	func cameraSessionViewDidChangeZoomLevel(_ cameraSessionView: CameraSessionView)
	func cameraSessionViewDidSwitchTorch(_ cameraSessionView: CameraSessionView)

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

	// Optional; called on runtime error or interruption. The UI can show a button that allows to resume the sesion manually using the resumeSession() call
	func cameraSessionView(_ cameraSessionView: CameraSessionView, wasInterruptedWithError: Error?)
	func cameraSessionView(_ cameraSessionView: CameraSessionView, wasInterruptedWithReason: AVCaptureSession.InterruptionReason)

	// Optional; called in response to resumeInterruptedSession()
	func cameraSessionView(_ cameraSessionView: CameraSessionView, didResumeInterruptedSessionWithResult: Bool)
}


extension CameraSessionViewDelegate {
	// Default implementations of optional methods:
	func cameraSessionViewDidChangeZoomLevel(_ cameraSessionView: CameraSessionView) {}
	func cameraSessionViewDidSwitchTorch(_ cameraSessionView: CameraSessionView) {}
	func cameraSessionViewWillCapturePhoto(_ cameraSessionView: CameraSessionView) {}
	func cameraSessionView(_ cameraSessionView: CameraSessionView, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {}
	func cameraSessionViewDidStartRecording(_ cameraSessionView: CameraSessionView) {}
	func cameraSessionView(_ cameraSessionView: CameraSessionView, wasInterruptedWithError: Error?) {}
	func cameraSessionView(_ cameraSessionView: CameraSessionView, wasInterruptedWithReason: AVCaptureSession.InterruptionReason) {}
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

	private(set)
	var hasFlash: Bool = false

	var zoomLevel: CGFloat = 1 {
		didSet {
			if !isSettingZoom {
				didSetZoomLevel()
			}
		}
	}

	var hasZoom: Bool {
		return !isFront
	}

	var isTorchOn: Bool = false {
		didSet {
			if !isSettingTorch {
				didSwitchTorch()
			}
		}
	}

	private(set)
	var hasTorch: Bool = false

	var isRecording: Bool {
		// Is this thread safe? Hopefully. But not terribly important because normally you won't use this flag, everything should be done via delegates.
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
			guard self.videoOutput != nil && self.audioOutput != nil else {
				return
			}
			self.prepareWriterChain(fileURL: fileURL)
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
			self.session.startRunning()
			let result = self.session.isRunning
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

	private var videoDeviceInput: AVCaptureDeviceInput!
	private var audioDeviceInput: AVCaptureDeviceInput?
	private var photoOutput: AVCapturePhotoOutput?
	private var backgroundRecordingID: UIBackgroundTaskIdentifier = .invalid

	private var videoOutput: AVCaptureVideoDataOutput?
	private var audioOutput: AVCaptureAudioDataOutput?
	private var videoWriterInput: AVAssetWriterInput?
	private var audioWriterInput: AVAssetWriterInput?
	private var videoWriter: AVAssetWriter?

	private var isSettingZoom: Bool = false // helps bypass didSet
	private var isSettingTorch: Bool = false


	private let videoDeviceDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInDualCamera, .builtInTelephotoCamera], mediaType: .video, position: .unspecified)
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
			self.configureSession()
		}
	}


	private func didSetZoomLevel() {
		queue.async {
			self.isSettingZoom = true
			if let videoDeviceInput = self.videoDeviceInput {
				self.trySetZoomLevel()
				self.zoomLevel = videoDeviceInput.device.videoZoomFactor
			}
			else {
				self.zoomLevel = 1
			}
			self.isSettingZoom = false
			DispatchQueue.main.async {
				self.delegate?.cameraSessionViewDidChangeZoomLevel(self)
			}
		}
	}


	private func didSwitchTorch() {
		self.isSettingTorch = true
		if let videoDeviceInput = self.videoDeviceInput {
			self.trySwitchTorch()
			self.isTorchOn = videoDeviceInput.device.torchMode == .on
		}
		else {
			self.isTorchOn = false
		}
		self.isSettingTorch = false
		DispatchQueue.main.async {
			self.delegate?.cameraSessionViewDidSwitchTorch(self)
		}
	}


	private func configureSession() {
		precondition(!Thread.isMainThread)

		guard status == .undefined || status == .configured else {
			return
		}

		session.beginConfiguration()

		session.sessionPreset = isPhoto ? .photo : .high

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

		DispatchQueue.main.async {
			self.delegate?.cameraSessionView(self, didCompleteConfigurationWithStatus: self.status)
		}
	}


	private func configureVideoInput() {
		precondition(!Thread.isMainThread)
		if videoDeviceInput == nil {
			do {
				self.hasFlash = false
				self.hasTorch = false
				if let videoDevice = findMatchingVideoDevice() {
					let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
					if session.canAddInput(videoDeviceInput) {
						session.addInput(videoDeviceInput)
						self.videoDeviceInput = videoDeviceInput
						self.hasFlash = videoDevice.isFlashAvailable
						if self.hasZoom {
							self.trySetZoomLevel()
						}
						self.hasTorch = videoDevice.hasTorch
						if self.hasTorch {
							queue.async {
								self.trySwitchTorch()
							}
						}
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


	private func trySetZoomLevel() {
		do {
			try videoDeviceInput.device.lockForConfiguration()
			videoDeviceInput.device.videoZoomFactor = zoomLevel
			videoDeviceInput.device.unlockForConfiguration()
		} catch let error {
			print("CameraSessionView error: \(error)")
		}
	}


	private func trySwitchTorch() {
		// Additional protection here: trySwitchTorch() is called asynchronously during reconfiguration of the input device, because otherwise it flashes and turns itself off for some reason.
		if let videoDeviceInput = videoDeviceInput {
			do {
				try videoDeviceInput.device.lockForConfiguration()
				videoDeviceInput.device.torchMode = isTorchOn ? .on : .off
				videoDeviceInput.device.unlockForConfiguration()
			} catch let error {
				print("CameraSessionView error: \(error)")
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


	private func prepareWriterChain(fileURL: URL) {
		precondition(!Thread.isMainThread)

		let videoWriter = try! AVAssetWriter(url: fileURL, fileType: VIDEO_FILE_TYPE)

		let codec = videoOutput!.availableVideoCodecTypes.contains(BEST_VIDEO_CODEC_TYPE) ? BEST_VIDEO_CODEC_TYPE : FALLBACK_VIDEO_CODE_TYPE
		print("Using", codec == BEST_VIDEO_CODEC_TYPE ? "h5" : "h4", "codec")
		let videoSettings = [
				AVVideoCodecKey: codec,
				AVVideoWidthKey: VIDEO_BUFFER_DIMENSIONS.width,
				AVVideoHeightKey: VIDEO_BUFFER_DIMENSIONS.height,
				AVVideoScalingModeKey : AVVideoScalingModeResizeAspectFill,
				AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: VIDEO_BITRATE]
			] as [String : Any]
		let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
		videoWriterInput.expectsMediaDataInRealTime = true
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
		self.videoWriter = videoWriter // order is important
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
			if videoWriter.status == .unknown, let pixelBuf = CMSampleBufferGetImageBuffer(sampleBuffer) {
				videoWriter.startWriting()
				videoWriter.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
				let width = CVPixelBufferGetWidth(pixelBuf)
				let height = CVPixelBufferGetHeight(pixelBuf)
				DispatchQueue.main.async {
					print("Video recording started with \(width):\(height)")
					self.delegate?.cameraSessionViewDidStartRecording(self)
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
		delegate?.cameraSessionView(self, wasInterruptedWithError: error)
	}


	@objc func sessionWasInterrupted(notification: NSNotification) {
		if let userInfoValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as AnyObject?,
			let reasonIntegerValue = userInfoValue.integerValue,
			let reason = AVCaptureSession.InterruptionReason(rawValue: reasonIntegerValue) {
			print("CameraSessionView error: Capture session was interrupted with reason \(reason.rawValue)")
			delegate?.cameraSessionView(self, wasInterruptedWithReason: reason)
		}
	}


	@objc func sessionInterruptionEnded(notification: NSNotification) {
		print("CameraSessionView error: Capture session interruption ended")
		delegate?.cameraSessionView(self, didResumeInterruptedSessionWithResult: true)
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
