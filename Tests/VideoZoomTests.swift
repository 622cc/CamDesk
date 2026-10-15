import AppKit
import Foundation

@main struct VideoZoomTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        assert(VideoZoom.clamp(.nan)==1 && VideoZoom.clamp(.infinity)==1)
        assert(VideoZoom.clamp(0)==1 && VideoZoom.clamp(10)==8)
        assert(VideoZoom.stepped(1,up:true)==1.25)
        assert(VideoZoom.stepped(1.25,up:false)==1)
        let window=NSWindow(contentRect:NSRect(x:100,y:100,width:640,height:480),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        let view=VideoMagnificationScrollView(frame:NSRect(x:0,y:0,width:640,height:480))
        let image=NSImage(size:NSSize(width:640,height:480))
        image.lockFocus()
        NSColor.red.setFill();NSRect(x:0,y:0,width:320,height:480).fill()
        NSColor.blue.setFill();NSRect(x:320,y:0,width:320,height:480).fill()
        NSColor.white.setFill();NSRect(x:220,y:140,width:80,height:120).fill()
        image.unlockFocus();view.picture.image=image
        window.contentView=view;window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded();view.layout()
        let original=view.documentVisibleRect
        let before=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
        view.cacheDisplay(in:view.bounds,to:before)
        view.setMagnification(2,centeredAt:NSPoint(x:320,y:240));view.layout()
        let enlarged=view.documentVisibleRect
        assert(abs(view.magnification-2)<0.001)
        assert(enlarged.width<original.width*0.6 && enlarged.height<original.height*0.6,"Zoom did not shrink visible document rect")
        let after=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
        view.cacheDisplay(in:view.bounds,to:after)
        assert(before.representation(using:.png,properties:[:]) != after.representation(using:.png,properties:[:]),"Rendered pixels did not change")
        print("PASS 2x native magnification changes visible rectangle and rendered pixels")
        let start=view.documentVisibleRect.origin
        let down=NSEvent.mouseEvent(with:.leftMouseDown,location:NSPoint(x:200,y:200),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
        let drag=NSEvent.mouseEvent(with:.leftMouseDragged,location:NSPoint(x:240,y:220),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
        view.picture.mouseDown(with:down);view.picture.mouseDragged(with:drag);view.picture.mouseUp(with:drag)
        assert(view.documentVisibleRect.origin != start,"Drag did not pan zoomed image")
        print("PASS dragging pans magnified video")
        var callback=0.0;view.onMagnificationChange={callback=$0}
        let wheel=CGEvent(scrollWheelEvent2Source:nil,units:.line,wheelCount:1,wheel1:3,wheel2:0,wheel3:0)!
        wheel.location=NSPoint(x:200,y:200)
        view.picture.scrollWheel(with:NSEvent(cgEvent:wheel)!)
        assert(view.magnification>2 && callback>2,"Wheel did not zoom")
        print("PASS wheel magnification updates displayed zoom state")
        let doubleClick=NSEvent.mouseEvent(with:.leftMouseDown,location:NSPoint(x:200,y:200),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:2,pressure:1)!
        view.picture.mouseDown(with:doubleClick)
        assert(view.magnification==1 && callback==1)
        print("PASS double-click restores 1x")
        print("ALL VIDEO ZOOM TESTS PASSED")
    }
}
