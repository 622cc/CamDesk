import SwiftUI
import AppKit

// Uses the native scroll view's magnification and panning instead of transforming
// a SwiftUI image outside its viewport. Scaling is strictly local display state.
enum VideoZoom {
    static func clamp(_ value:Double)->Double {value.isFinite ? min(8,max(1,value)):1}
    static func stepped(_ value:Double,up:Bool)->Double {clamp(value*(up ? 1.25:0.8))}
}
struct ZoomVideoSurface:View {
    @ObservedObject var player:CameraPlayer
    @Binding var zoom:Double
    var body:some View {
        ZStack {
            Color.black
            MagnifiedVideo(image:player.image,zoom:$zoom)
            if player.image==nil {Text(player.status).foregroundStyle(.white).padding().allowsHitTesting(false)}
        }.clipped()
    }
}
struct MagnifiedVideo:NSViewRepresentable {
    let image:NSImage?
    @Binding var zoom:Double
    func makeNSView(context:Context)->VideoMagnificationScrollView {
        let view=VideoMagnificationScrollView()
        view.onMagnificationChange={value in
            DispatchQueue.main.async {self.zoom=value}
        }
        return view
    }
    func updateNSView(_ view:VideoMagnificationScrollView,context:Context) {
        view.picture.image=image
        view.onMagnificationChange={value in DispatchQueue.main.async {self.zoom=value}}
        let value=VideoZoom.clamp(zoom)
        if abs(view.magnification-value)>0.001 {
            view.setMagnification(CGFloat(value),centeredAt:NSPoint(x:view.documentVisibleRect.midX,y:view.documentVisibleRect.midY))
        }
    }
}
final class ZoomImageView:NSImageView {
    override func mouseDown(with event:NSEvent){enclosingScrollView?.mouseDown(with:event)}
    override func mouseDragged(with event:NSEvent){enclosingScrollView?.mouseDragged(with:event)}
    override func mouseUp(with event:NSEvent){enclosingScrollView?.mouseUp(with:event)}
    override func scrollWheel(with event:NSEvent){enclosingScrollView?.scrollWheel(with:event)}
    override func magnify(with event:NSEvent){enclosingScrollView?.magnify(with:event)}
    override func resetCursorRects(){addCursorRect(bounds,cursor:.openHand)}
}
final class VideoMagnificationScrollView:NSScrollView {
    let picture=ZoomImageView()
    var onMagnificationChange:((Double)->Void)?
    private var dragPoint:NSPoint?
    override init(frame:NSRect) {
        super.init(frame:frame)
        drawsBackground=true;backgroundColor = .black
        allowsMagnification=true;minMagnification=1;maxMagnification=8
        hasHorizontalScroller=false;hasVerticalScroller=false
        borderType = .noBorder
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.imageAlignment = .alignCenter
        documentView=picture
        setAccessibilityLabel("视频画面：滚轮或捏合缩放，拖动查看，双击还原")
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
    override func layout() {
        let oldVisible=documentVisibleRect
        super.layout()
        // The document's unscaled size stays equal to the viewport at 1×.
        let size=contentSize
        if picture.frame.size != size {
            picture.setFrameSize(size)
            if magnification>1 {setMagnification(magnification,centeredAt:NSPoint(x:oldVisible.midX,y:oldVisible.midY))}
        }
    }
    override func scrollWheel(with event:NSEvent) {
        if event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.option) {
            super.scrollWheel(with:event)
        } else {
            let factor=exp(event.scrollingDeltaY*0.06)
            let point=picture.convert(event.locationInWindow,from:nil)
            setMagnification(CGFloat(VideoZoom.clamp(Double(magnification)*factor)),centeredAt:point)
            onMagnificationChange?(Double(magnification))
        }
    }
    override func magnify(with event:NSEvent) {
        super.magnify(with:event)
        onMagnificationChange?(Double(magnification))
    }
    override func mouseDown(with event:NSEvent) {
        if event.clickCount==2 {
            setMagnification(1,centeredAt:NSPoint(x:picture.bounds.midX,y:picture.bounds.midY));onMagnificationChange?(1)
        } else {dragPoint=event.locationInWindow}
    }
    override func mouseDragged(with event:NSEvent) {
        guard let old=dragPoint,magnification>1 else{return}
        let current=event.locationInWindow
        var origin=contentView.bounds.origin
        origin.x-=(current.x-old.x)/magnification
        origin.y-=(current.y-old.y)/magnification
        contentView.scroll(to:origin);reflectScrolledClipView(contentView);dragPoint=current
    }
    override func mouseUp(with event:NSEvent){dragPoint=nil}
}
