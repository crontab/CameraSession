//
//  VideoEffects.swift
//  CameraSession
//
//  Created by Hovik Melikyan on 10/09/2019.
//  Copyright © 2019 Apple. All rights reserved.
//

import Foundation
import MetalPetal



class VideoEffects {

	enum FilterType {
		case color
		case monochrome

		fileprivate func image() -> UIImage {
			switch self {
			case .color: return UIImage(named: "filter_lookup_fuji2")!
			case .monochrome: return UIImage(named: "filter_lookup_bw")!
			}
		}

		fileprivate func filter() -> MTIColorLookupFilter {
			let filter = MTIColorLookupFilter()
			filter.inputColorLookupTable = MTIImage(cgImage: image().cgImage!, options: [MTKTextureLoader.Option.SRGB: false], isOpaque: true)
			return filter
		}
	}


	var filterType: FilterType {
		didSet {
			colorLookupFilter = filterType.filter()
		}
	}


	private var dimensions: CGSize
	private var context: MTIContext
	private var colorLookupFilter: MTIColorLookupFilter
	private var pixelBufferPool: CVPixelBufferPool


	init(dimensions: CGSize, initialFilterType: FilterType) {
		self.dimensions = dimensions
		self.context = try! MTIContext(device: MTLCreateSystemDefaultDevice()!)
		self.filterType = initialFilterType
		self.colorLookupFilter = filterType.filter()

		let sourcePixelBufferOptions: NSDictionary = [
			kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
			kCVPixelBufferWidthKey: dimensions.width,
			kCVPixelBufferHeightKey: dimensions.height,
			// kCVPixelFormatOpenGLESCompatibility: true,
			kCVPixelBufferIOSurfacePropertiesKey: NSDictionary()]
		let pixelBufferPoolOptions: NSDictionary = [kCVPixelBufferPoolMinimumBufferCountKey: 30]
		var pixelBufferPool: CVPixelBufferPool?
		CVPixelBufferPoolCreate(kCFAllocatorDefault, pixelBufferPoolOptions, sourcePixelBufferOptions, &pixelBufferPool)
		self.pixelBufferPool = pixelBufferPool!
	}


//	func applyLookupEffect(on sampleBuffer: CMSampleBuffer) -> (CMSampleBuffer, MTIImage)? {
//
//		guard let pixelBuffer: CVPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
//			return nil
//		}
//
//		// Apply effect
//		let inputImage = MTIImage(cvPixelBuffer: pixelBuffer, alphaType: .alphaIsOne)
//		colorLookupFilter.inputImage = inputImage
//		guard let outputImage = colorLookupFilter.outputImage?.withCachePolicy(.persistent) else {
//			preconditionFailure()
//		}
//
//		// Render output image to pixelBuffer
//		var outputPixelBuffer : CVPixelBuffer?
//		let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &outputPixelBuffer)
//		precondition(status == kCVReturnSuccess)
//		try! context.render(outputImage, to: outputPixelBuffer!)
//
//		return (SampleBufferByReplacingImageBuffer(sampleBuffer: sampleBuffer, imageBuffer: outputPixelBuffer!), outputImage)
//	}


	func applyEffect(on sampleBuffer: CMSampleBuffer) -> MTIImage? {
		guard let pixelBuffer: CVPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
			return nil
		}
		let inputImage = MTIImage(cvPixelBuffer: pixelBuffer, alphaType: .alphaIsOne)
		colorLookupFilter.inputImage = inputImage
		return colorLookupFilter.outputImage?.withCachePolicy(.persistent)
	}


	private func SampleBufferByReplacingImageBuffer(sampleBuffer: CMSampleBuffer, imageBuffer: CVPixelBuffer) -> CMSampleBuffer {
		var timeingInfo = CMSampleTimingInfo()
		CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timeingInfo)
		var outputSampleBuffer: CMSampleBuffer?
		var formatDescription: CMFormatDescription?
		CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: imageBuffer, formatDescriptionOut: &formatDescription)
		CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: imageBuffer, formatDescription: formatDescription!, sampleTiming: &timeingInfo, sampleBufferOut: &outputSampleBuffer)
		return outputSampleBuffer!
	}
}

