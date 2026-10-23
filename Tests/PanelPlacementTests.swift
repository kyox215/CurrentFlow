import Foundation
import CoreGraphics

@main
struct PanelPlacementTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        count += 1
        precondition(condition(), message)
    }

    static func main() {
        let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 70, width: 1512, height: 874)
        let safe = PanelPlacement.safeBounds(screen: laptop, visible: visible, safeTop: 38)
        check(safe.maxY <= 944, "面板顶部在刘海与菜单栏下方")
        for x in [0.0, 10, 500, 750, 1300, 1512, 2000] {
            let anchor = CGRect(x: x, y: 944, width: 92, height: 38)
            let frame = PanelPlacement.frame(in: safe, anchor: anchor)
            check(safe.contains(frame), "任何菜单栏位置都不能把面板移出屏幕")
            check(frame.size == PanelPlacement.preferredSize, "空间足够时保持固定尺寸")
        }
        let tiny = CGRect(x: -300, y: 100, width: 300, height: 260)
        let tinyVisible = CGRect(x: -300, y: 120, width: 300, height: 216)
        let tinySafe = PanelPlacement.safeBounds(screen: tiny, visible: tinyVisible, safeTop: 0)
        let tinyPanel = PanelPlacement.frame(in: tinySafe, anchor: CGRect(x: -10, y: 456, width: 28, height: 24))
        check(tinySafe.contains(tinyPanel), "小屏幕缩小面板并保持屏内")
        check(tinyPanel.width < PanelPlacement.preferredSize.width && tinyPanel.height < PanelPlacement.preferredSize.height, "小屏幕不强制最小高度导致溢出")
        let external = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        let externalVisible = CGRect(x: -1872, y: -300, width: 1872, height: 1056)
        let externalSafe = PanelPlacement.safeBounds(screen: external, visible: externalVisible, safeTop: 0)
        let externalPanel = PanelPlacement.frame(in: externalSafe, anchor: nil)
        check(externalSafe.contains(externalPanel), "负坐标外接显示器")
        check(externalPanel.minX >= -1862, "避开侧边 Dock")
        let autoHidden = PanelPlacement.safeBounds(screen: laptop, visible: laptop, safeTop: 38)
        check(autoHidden.maxY <= laptop.maxY - 38, "菜单栏自动隐藏也必须避开刘海")

        let menuAreas = [CGRect(x: 0, y: 944, width: 650, height: 38), CGRect(x: 862, y: 944, width: 650, height: 38)]
        check(PanelPlacement.menuItemFits(CGRect(x: 1000, y: 944, width: 92, height: 38), screen: laptop, unobscuredTopAreas: menuAreas), "右侧安全区的紧凑读数")
        check(!PanelPlacement.menuItemFits(CGRect(x: 630, y: 944, width: 92, height: 38), screen: laptop, unobscuredTopAreas: menuAreas), "跨到刘海的读数触发纯图标回退")
        check(!PanelPlacement.menuItemFits(CGRect(x: 1510, y: 944, width: 92, height: 38), screen: laptop, unobscuredTopAreas: menuAreas), "不能越过屏幕右边缘")
        check(PanelPlacement.menuItemFits(CGRect(x: -120, y: 756, width: 92, height: 24), screen: external, unobscuredTopAreas: []), "普通外接显示器的菜单栏")
        print("PASS: \(count) placement checks — notch / edges / small display / external display / Dock / compact menu")
    }
}
