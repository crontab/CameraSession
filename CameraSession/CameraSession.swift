//
//  CameraSession.swift
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
private let BEST_VIDEO_DIMENSIONS = CGSize(width: 1080, height: 1920)
private let FALLBACK_VIDEO_DIMENSIONS = CGSize(width: 720, height: 1280)
private let VIDEO_BITRATE = 10 * 1024 * 1024
private let ORIENTATION = AVCaptureVideoOrientation.portrait



public protocol CameraSessionDelegate: class {

	// Called after the session has been configured or reconfigured as a result of changes in input device, capture mode (photo vs. video). Can be used to e.g. enable UI controls that you should disable before making any changes in the configuration.
	func cameraSession(_ cameraSession: CameraSession, didCompleteConfigurationWithStatus status: CameraSession.Status)

	// Optional. Called in response to assigning zoomLevel, which at this point will hold the real zoom level. Same for the torch.
	func cameraSessionDidChangeZoomLevel(_ cameraSession: CameraSession)
	func cameraSessionDidSwitchTorch(_ cameraSession: CameraSession)

	// Called when photo data is available after the call to capturePhoto(). Normally you would get the data via photo.fileDataRepresentation. Note that this method can be called multiple times in case both raw and another format was requested, or if operating in bracket mode (currently neither is supported by CameraSession)
	func cameraSession(_ cameraSession: CameraSession, didCapturePhoto photo: AVCapturePhoto?, error: Error?)

	// Optional; can be used to animate the capture, e.g. flash the screen or make sound
	func cameraSessionWillCapturePhoto(_ cameraSession: CameraSession)

	// Optional; called when all photo output formats have been delivered via cameraSession(_, didCapturePhoto:, error:)
	func cameraSession(_ cameraSession: CameraSession, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?)

	// Optional
	func cameraSessionDidStartRecording(_ cameraSession: CameraSession)

	// Does what it says; note that it is possible to have multiple recording processess finishing if background recording is enabled on the system; therefore it is recommended to have a unique/random temp file in each call to startRecording().
	func cameraSession(_ cameraSession: CameraSession, didFinishRecordingTo fileUrl: URL, error: Error?)

	// Optional; called on runtime error or interruption. The UI can show a button that allows to resume the sesion manually using the resumeSession() call
	func cameraSession(_ cameraSession: CameraSession, wasInterruptedWithError: Error?)
	func cameraSession(_ cameraSession: CameraSession, wasInterruptedWithReason: AVCaptureSession.InterruptionReason)

	// Optional; called in response to resumeInterruptedSession()
	func cameraSession(_ cameraSession: CameraSession, didResumeInterruptedSessionWithResult: Bool)

	// Optional; buffer-level processing e.g. for video effects.
	// NOTE: called on a non-GUI thread
	func cameraSession(_ cameraSession: CameraSession, didCaptureBuffer sampleBuffer: CMSampleBuffer) -> CMSampleBuffer
}



public extension CameraSessionDelegate {
	// Default implementations of optional methods:
	func cameraSessionDidChangeZoomLevel(_ cameraSession: CameraSession) {}
	func cameraSessionDidSwitchTorch(_ cameraSession: CameraSession) {}
	func cameraSession(_ cameraSession: CameraSession, didCapturePhoto photo: AVCapturePhoto?, error: Error?) {}
	func cameraSessionWillCapturePhoto(_ cameraSession: CameraSession) {}
	func cameraSession(_ cameraSession: CameraSession, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {}
	func cameraSessionDidStartRecording(_ cameraSession: CameraSession) {}
	func cameraSession(_ cameraSession: CameraSession, didFinishRecordingTo fileUrl: URL, error: Error?) {}
	func cameraSession(_ cameraSession: CameraSession, wasInterruptedWithError: Error?) {}
	func cameraSession(_ cameraSession: CameraSession, wasInterruptedWithReason: AVCaptureSession.InterruptionReason) {}
	func cameraSession(_ cameraSession: CameraSession, didResumeInterruptedSessionWithResult: Bool) {}
	func cameraSession(_ cameraSession: CameraSession, didCaptureBuffer sampleBuffer: CMSampleBuffer) -> CMSampleBuffer { return sampleBuffer }
}



public class CameraPreview: UIView {

	override public class var layerClass: AnyClass { return AVCaptureVideoPreviewLayer.self }

	var videoPreviewLayer: AVCaptureVideoPreviewLayer { return layer as! AVCaptureVideoPreviewLayer }

	public func setCameraSession(_ cameraSession: CameraSession) {
		videoPreviewLayer.session = cameraSession.session
		videoPreviewLayer.videoGravity = .resizeAspectFill
		videoPreviewLayer.connection?.videoOrientation = ORIENTATION
	}
}



public class CameraSession: NSObject, AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

	public enum Status: Equatable {
		case undefined
		case configured
		case notAuthorized
		case configurationFailed(message: String)
	}


	public var isFront: Bool = false {
		didSet {
			if status == .configured && oldValue != isFront {
				didSwitchCameraPosition()
			}
		}
	}

	public var hasBackAndFront: Bool {
		return videoDeviceDiscoverySession.uniqueDevicePositions.count > 1
	}

	public var isFlashEnabled: Bool = true // actually means automatic or off

	public private(set)
	var hasFlash: Bool = false

	public var zoomLevel: CGFloat = 1 {
		didSet {
			if !isSettingZoom {
				didSetZoomLevel()
			}
		}
	}

	public var hasZoom: Bool {
		return !isFront
	}

	public var isTorchOn: Bool = false {
		didSet {
			if !isSettingTorch {
				didSwitchTorch()
			}
		}
	}

	public private(set)
	var hasTorch: Bool = false

	public var isRecording: Bool {
		// Is this thread safe? Hopefully. But not terribly important because normally you won't use this flag, everything should be done via delegates.
		return assetWriter != nil
	}

	public private(set)
	var videoDimensions: CGSize?

	public private(set)
	var videoCodec: AVVideoCodecType?


	public init(delegate: CameraSessionDelegate, isFront: Bool) {
		super.init()

		precondition(status == .undefined)
		precondition(Thread.isMainThread)

		self.delegate = delegate
		self.isFront = isFront

		checkAuthorization() // runs on main thread, blocks the session thread if UI is involved

		queue.async {
			self.configureSession()
		}
	}


	deinit {
		removeAllObservers()
#if DEBUG
		print("CameraSession: deinit")
#endif
	}


	public func startSession(completion: (() -> Void)? = nil) {
		queue.async {
			self.configureSession()
			completion?()
		}
	}


	public func stopSession(completion: (() -> Void)? = nil) {
		queue.async {
			self.session.stopRunning()
			DispatchQueue.main.async {
				completion?()
			}
		}
	}


	public func capturePhoto() {
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


	public func startVideoRecording(toFileURL fileURL: URL) {
		queue.async {
			guard !self.isRecording else {
				return
			}
			precondition(self.assetWriter == nil && self.videoWriterInput == nil && self.audioWriterInput == nil)
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


	public func stopVideoRecording() {
		queue.async {
			guard self.assetWriter != nil else {
				return
			}
			DispatchQueue.main.async {
				if self.backgroundRecordingID != .invalid {
					UIApplication.shared.endBackgroundTask(self.backgroundRecordingID)
					self.backgroundRecordingID = .invalid
				}
			}
			self.audioWriterInput!.markAsFinished() // and let the video finish too before closing writing
		}
	}


	public func focus(with focusMode: AVCaptureDevice.FocusMode, exposureMode: AVCaptureDevice.ExposureMode, atDevicePoint devicePoint: CGPoint,  monitorSubjectAreaChange: Bool) {
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
				print("CameraSession error: Could not lock device for configuration: \(error)")
			}
		}
	}


	public func resumeInterruptedSession() {
		queue.async {
			self.session.startRunning()
			let result = self.session.isRunning
			DispatchQueue.main.async {
				self.delegate?.cameraSession(self, didResumeInterruptedSessionWithResult: result)
			}
		}
	}


	fileprivate var session = AVCaptureSession()
	private var queue = DispatchQueue(label: "com.melikyan.cameraSession.queue")

	private weak var delegate: CameraSessionDelegate?
	private var status: Status = .undefined

	private var videoDeviceInput: AVCaptureDeviceInput!
	private var audioDeviceInput: AVCaptureDeviceInput?
	private var photoOutput: AVCapturePhotoOutput?
	private var backgroundRecordingID: UIBackgroundTaskIdentifier = .invalid

	private var videoOutput: AVCaptureVideoDataOutput?
	private var audioOutput: AVCaptureAudioDataOutput?
	private var videoWriterInput: AVAssetWriterInput?
	private var audioWriterInput: AVAssetWriterInput?
	private var assetWriter: AVAssetWriter?

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


	private func didSwitchCameraPosition() {
		queue.async {
			guard !self.isRecording else {
				return
			}
			let isRunning = self.session.isRunning
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
			if isRunning {
				self.configureSession()
			}
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
				self.delegate?.cameraSessionDidChangeZoomLevel(self)
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
			self.delegate?.cameraSessionDidSwitchTorch(self)
		}
	}


	private func configureSession() {
		precondition(!Thread.isMainThread)

		guard status == .undefined || status == .configured else {
			return
		}

		session.beginConfiguration()

		session.sessionPreset = .high

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
			self.delegate?.cameraSession(self, didCompleteConfigurationWithStatus: self.status)
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
			print("CameraSession error: \(error)")
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
				print("CameraSession error: \(error)")
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
		if audioDeviceInput == nil {
			do {
				let audioDevice = AVCaptureDevice.default(for: .audio)
				let audioDeviceInput = try AVCaptureDeviceInput(device: audioDevice!)
				if session.canAddInput(audioDeviceInput) {
					session.addInput(audioDeviceInput)
					self.audioDeviceInput = audioDeviceInput
				} else {
					print("CameraSession error: Could not add audio device input to the session")
				}
			} catch {
				print("CameraSession error: Could not create audio device input: \(error)")
			}
		}
	}


	private func configureVideoOutput() {
		precondition(!Thread.isMainThread)
		if videoOutput == nil {
			let videoOutput = AVCaptureVideoDataOutput()
			if session.canAddOutput(videoOutput) {
				session.addOutput(videoOutput)
				if let connection = videoOutput.connection(with: .video) {
					connection.videoOrientation = ORIENTATION
					if connection.isVideoStabilizationSupported {
						connection.preferredVideoStabilizationMode = .off
					}
				}
				else {
					print("CameraSession error: no video output connection")
				}
				// kCVPixelFormatType_420YpCbCr8BiPlanarFullRange if supported
				videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as [String : Any]
				videoOutput.alwaysDiscardsLateVideoFrames = true
				videoOutput.setSampleBufferDelegate(self, queue: self.queue /* DispatchQueue.global(qos: .default) */)
				self.videoOutput = videoOutput

				let useBest = videoOutput.availableVideoCodecTypesForAssetWriter(writingTo: VIDEO_FILE_TYPE).contains(BEST_VIDEO_CODEC_TYPE)
				print("CameraSession: using \(useBest ? "best" : "fallback") codec and dimensions")
				self.videoCodec = useBest ? BEST_VIDEO_CODEC_TYPE : FALLBACK_VIDEO_CODE_TYPE
				self.videoDimensions = useBest ? BEST_VIDEO_DIMENSIONS : FALLBACK_VIDEO_DIMENSIONS
			}
		}
	}


	private func configureAudioOutput() {
		precondition(!Thread.isMainThread)
		if audioOutput == nil {
			let audioOutput = AVCaptureAudioDataOutput()
			if session.canAddOutput(audioOutput) {
				audioOutput.setSampleBufferDelegate(self, queue: self.queue /* DispatchQueue.global(qos: .default) */)
				session.addOutput(audioOutput)
				self.audioOutput = audioOutput
			}
		}
	}


	private func prepareWriterChain(fileURL: URL) {
		precondition(!Thread.isMainThread)

		let assetWriter = try! AVAssetWriter(url: fileURL, fileType: VIDEO_FILE_TYPE)

		let videoSettings = [
			AVVideoCodecKey: videoCodec!,
			AVVideoWidthKey: videoDimensions!.width,
			AVVideoHeightKey: videoDimensions!.height,
			AVVideoScalingModeKey : AVVideoScalingModeResizeAspectFill,
			AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: VIDEO_BITRATE]
			] as [String : Any]
		let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
		videoWriterInput.expectsMediaDataInRealTime = true
		assetWriter.add(videoWriterInput)

		let audioSettings = [
			AVFormatIDKey: AUDIO_FORMAT,
			AVSampleRateKey: AUDIO_SAMPLING_RATE,
			AVNumberOfChannelsKey: 1,
			// AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue // this is a iOS 12+ feature, though strangely the constants are available on iOS 11 too.
			] as [String : Any]
		let audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
		audioWriterInput.expectsMediaDataInRealTime = true
		assetWriter.add(audioWriterInput)

		self.videoWriterInput = videoWriterInput
		self.audioWriterInput = audioWriterInput
		self.assetWriter = assetWriter // order is important
	}


	private func configurePhotoOutput() {
		precondition(!Thread.isMainThread)
		if photoOutput == nil {
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
			self.delegate?.cameraSession(self, didCompleteConfigurationWithStatus: self.status)
		}
	}


	// - - -  CAPTURE/RECORDING DELEGATES

	public func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
		DispatchQueue.main.async {
			self.delegate?.cameraSessionWillCapturePhoto(self)
		}
	}


	public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
		DispatchQueue.main.async {
			self.delegate?.cameraSession(self, didCapturePhoto: photo, error: error)
		}
	}


	public func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
		DispatchQueue.main.async {
			self.delegate?.cameraSession(self, didFinishCaptureFor: resolvedSettings, error: error)
		}
	}


	private var startTs: CMTime?

	public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {

		let ts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
		let isVideo = output == self.videoOutput
		let isAudio = output == self.audioOutput

		var sampleBuffer = sampleBuffer
		if isVideo, let delegate = delegate {
			sampleBuffer = delegate.cameraSession(self, didCaptureBuffer: sampleBuffer)
		}

		guard let assetWriter = self.assetWriter else {
			return
		}

		switch assetWriter.status {
		case .unknown:
			assetWriter.startWriting()
			startTs = ts
			assetWriter.startSession(atSourceTime: startTs!)
			writeSampleBuffer(sampleBuffer, isVideo: isVideo, isAudio: isAudio)
			DispatchQueue.main.async {
				self.delegate?.cameraSessionDidStartRecording(self)
			}

		case .writing:
			writeSampleBuffer(sampleBuffer, isVideo: isVideo, isAudio: isAudio)

		case .completed, .failed, .cancelled:
			startTs = nil
			self.assetWriter = nil
			self.videoWriterInput = nil
			self.audioWriterInput = nil
			let error = assetWriter.status == .failed ? assetWriter.error : nil
			DispatchQueue.main.async {
				self.delegate?.cameraSession(self, didFinishRecordingTo: assetWriter.outputURL, error: error)
			}
			break

		@unknown default:
			break
		}
	}


	private func writeSampleBuffer(_ sampleBuffer: CMSampleBuffer, isVideo: Bool, isAudio: Bool) {
		guard let assetWriter = self.assetWriter, let videoWriterInput = self.videoWriterInput, let audioWriterInput = self.audioWriterInput else {
			return
		}
		// let ts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
		if isVideo {
			if videoWriterInput.isReadyForMoreMediaData {
				// print("V", CMTimeGetSeconds(CMTimeSubtract(ts, startTs!)))
				videoWriterInput.append(sampleBuffer)
				if !audioWriterInput.isReadyForMoreMediaData {
					videoWriterInput.markAsFinished()
					assetWriter.finishWriting {
					}
				}
			}
		}
		else if isAudio {
			if audioWriterInput.isReadyForMoreMediaData {
				// print("A", CMTimeGetSeconds(CMTimeSubtract(ts, startTs!)))
				audioWriterInput.append(sampleBuffer)
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
		// TODO: this should move to CameraPreview
//		let point = CGPoint(x: bounds.midX, y: bounds.midY)
//		focus(with: .continuousAutoFocus, exposureMode: .continuousAutoExposure, atPoint: point, monitorSubjectAreaChange: false)
	}


	@objc func sessionRuntimeError(notification: NSNotification) {
		guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else { return }
		delegate?.cameraSession(self, wasInterruptedWithError: error)
	}


	@objc func sessionWasInterrupted(notification: NSNotification) {
		if let userInfoValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as AnyObject?,
			let reasonIntegerValue = userInfoValue.integerValue,
			let reason = AVCaptureSession.InterruptionReason(rawValue: reasonIntegerValue) {
			print("CameraSession error: Capture session was interrupted with reason \(reason.rawValue)")
			delegate?.cameraSession(self, wasInterruptedWithReason: reason)
		}
	}


	@objc func sessionInterruptionEnded(notification: NSNotification) {
		print("CameraSession error: Capture session interruption ended")
		delegate?.cameraSession(self, didResumeInterruptedSessionWithResult: true)
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
