import AppKit
let destination=CommandLine.arguments[1]
let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1024,pixelsHigh:1024,bitsPerSample:8,samplesPerPixel:3,hasAlpha:false,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
let green=NSColor(srgbRed:0.055,green:0.28,blue:0.27,alpha:1)
green.setFill(); NSBezierPath(rect:NSRect(x:0,y:0,width:1024,height:1024)).fill()
NSColor(srgbRed:0.88,green:0.98,blue:0.96,alpha:1).setFill()
NSBezierPath(roundedRect:NSRect(x:166,y:260,width:692,height:480),xRadius:70,yRadius:70).fill()
green.setFill(); NSBezierPath(roundedRect:NSRect(x:190,y:285,width:644,height:125),xRadius:48,yRadius:48).fill()
NSColor.white.setFill();NSBezierPath(ovalIn:NSRect(x:726,y:322,width:48,height:48)).fill()
NSGraphicsContext.restoreGraphicsState(); try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:destination))
