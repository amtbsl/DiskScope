import AppKit
let root = CommandLine.arguments[1]
try! FileManager.default.createDirectory(atPath:root,withIntermediateDirectories:true)
for size in [16,32,64,128,256,512,1024] {
    let image = NSImage(size:NSSize(width:size,height:size))
    image.lockFocus()
    let s = CGFloat(size), inset = s*0.06
    let base = NSBezierPath(roundedRect:NSRect(x:inset,y:inset,width:s-inset*2,height:s-inset*2),xRadius:s*0.2,yRadius:s*0.2)
    NSGradient(starting:NSColor(calibratedRed:0.12,green:0.55,blue:1,alpha:1),ending:NSColor(calibratedRed:0.02,green:0.23,blue:0.68,alpha:1))!.draw(in:base,angle:270)
    let segments:[(CGFloat,CGFloat,CGFloat,CGFloat,NSColor)] = [(0.22,0.26,0.31,0.47,.white),(0.56,0.49,0.22,0.24,NSColor.white.withAlphaComponent(0.8)),(0.56,0.26,0.22,0.2,NSColor.white.withAlphaComponent(0.5))]
    for (x,y,w,h,color) in segments { color.setFill(); NSBezierPath(roundedRect:NSRect(x:x*s,y:y*s,width:w*s,height:h*s),xRadius:s*0.025,yRadius:s*0.025).fill() }
    image.unlockFocus()
    let rep = NSBitmapImageRep(data:image.tiffRepresentation!)!
    try! rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:root+"/size\(size).png"))
}
