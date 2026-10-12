import AppKit

extension WorkRowCellView {
    func setFinished(_ value: Bool) {
        guard value != finished else { return }
        finished = value
        renderMeta()
    }

    func setKudosGiven(_ given: Bool) {
        guard given != kudosGiven else { return }
        kudosGiven = given
        renderMeta()
    }

    func renderMeta() {
        let font = MacFont.ui(11, weight: .medium)
        let line = NSMutableAttributedString(string: "♥", attributes: [
            .font: font,
            .foregroundColor: kudosGiven ? NSColor(srgbRed: 0xCE / 255, green: 0x51 / 255, blue: 0x4D / 255, alpha: 1) : theme.nsInk3,
        ])
        line.append(NSAttributedString(string: metaText, attributes: [
            .font: font, .foregroundColor: theme.nsInk3,
        ]))
        if finished {
            line.append(NSAttributedString(string: "   ✓ Finished", attributes: [
                .font: font, .foregroundColor: theme.nsInk2,
            ]))
        }
        metaLabel.attributedStringValue = line
    }

    func applyTheme() {
        layer?.backgroundColor = isRowSelected ? theme.nsAccentSoft.cgColor : NSColor.clear.cgColor
        selectionBar.layer?.backgroundColor = isRowSelected ? theme.nsAccent.cgColor : NSColor.clear.cgColor
        separator.layer?.backgroundColor = theme.nsLine.cgColor
        fandomLabel.textColor = theme.nsAccent
        titleLabel.textColor = theme.nsInk
        summaryLabel.textColor = theme.nsInk2
        renderMeta()
        datesLabel.textColor = theme.nsInk3
        newBadge.font = MacFont.ui(9, weight: .bold)
        newBadge.textColor = theme.nsAccent
        newBadge.layer?.backgroundColor = theme.nsAccentSoft.cgColor
        newBadge.layer?.borderColor = theme.nsAccent.withAlphaComponent(0.5).cgColor
        newBadge.layer?.borderWidth = 1
        removedBadge.font = MacFont.ui(9, weight: .bold)
        removedBadge.textColor = theme.nsAccent2
        removedBadge.layer?.backgroundColor = theme.nsAccent2.withAlphaComponent(0.13).cgColor
        removedBadge.layer?.borderColor = theme.nsAccent2.withAlphaComponent(0.5).cgColor
        removedBadge.layer?.borderWidth = 1
        progressTrack.layer?.backgroundColor = theme.nsSurface3.cgColor
        progressFill.layer?.backgroundColor = theme.nsAccent.cgColor
    }
}
