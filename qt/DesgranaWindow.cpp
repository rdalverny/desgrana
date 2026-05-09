// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
#include "DesgranaWindow.hpp"
#include "SplitWorker.hpp"
#include "include/desgrana_bridge.h"

#include <QApplication>
#include <QDateTime>
#include <QIcon>
#include <QDesktopServices>
#include <QDir>
#include <QDragEnterEvent>
#include <QDragLeaveEvent>
#include <QDropEvent>
#include <QFile>
#include <QFileDialog>
#include <QHBoxLayout>
#include <QJsonDocument>
#include <QJsonObject>
#include <QScrollArea>
#include <QLocale>
#include <QMimeData>
#include <QNetworkReply>
#include <QSettings>
#include <QStandardPaths>
#include <QStyle>
#include <QSysInfo>
#include <QThread>
#include <QUrlQuery>
#include <QVBoxLayout>
#include <algorithm>
#include <map>
#include <set>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------
// Palette-aware stylesheet helpers
// ---------------------------------------------------------------------------

static QString paletteRgba(const QColor &c) {
    return QString("rgba(%1,%2,%3,%4)")
        .arg(c.red()).arg(c.green()).arg(c.blue())
        .arg(qRound(c.alphaF() * 255));
}

static QString dropZoneIdleStyle(const QPalette &pal) {
    QColor b = pal.color(QPalette::PlaceholderText);
    b.setAlphaF(0.30);
    return QString("QFrame#dropZone { border: 2px dashed %1; border-radius: 12px; }")
        .arg(paletteRgba(b));
}

static QString dropZoneErrorStyle() {
    return "QFrame#dropZone { border: 2px dashed #FF3B30; border-radius: 12px; }";
}

static QString dropZoneTargetedStyle(const QPalette &pal) {
    QColor border = pal.color(QPalette::Highlight);
    QColor fill   = border;
    fill.setAlphaF(0.08);
    return QString(
        "QFrame#dropZone { border: 2px dashed %1; border-radius: 12px;"
        "                  background: %2; }")
        .arg(border.name(), paletteRgba(fill));
}

// ---------------------------------------------------------------------------
// DesgranaWindow
// ---------------------------------------------------------------------------

DesgranaWindow::DesgranaWindow(QWidget *parent) : QWidget(parent) {
    setWindowTitle("Desgrana");
    setMinimumWidth(480);
    setAcceptDrops(true);

    buildIdlePage();
    buildReadyPage();
    buildSplittingPage();
    buildDonePage();

    m_updateLabel = new QLabel(this);
    m_updateLabel->setAlignment(Qt::AlignCenter);
    m_updateLabel->setOpenExternalLinks(true);
    m_updateLabel->setVisible(false);
    m_updateLabel->setContentsMargins(0, 0, 0, 8);
    {
        QFont f = m_updateLabel->font();
        f.setPixelSize(11);
        m_updateLabel->setFont(f);
    }

    auto *root = new QVBoxLayout(this);
    root->setContentsMargins(0, 0, 0, 0);
    root->setSpacing(0);
    // Pages added directly — hidden widgets are excluded from QVBoxLayout's
    // sizeHint, so the window resizes to the visible page only.
    root->addWidget(m_idlePage);
    root->addWidget(m_readyPage);
    root->addWidget(m_splittingPage);
    root->addWidget(m_donePage);
    root->addWidget(m_updateLabel);

    m_readyPage->hide();
    m_splittingPage->hide();
    m_donePage->hide();

    showIdle();

    m_nam = new QNetworkAccessManager(this);
    connect(m_nam, &QNetworkAccessManager::finished, this, &DesgranaWindow::onUpdateReply);
    checkForUpdate();

    applyDynamicStyles();
}

// ---------------------------------------------------------------------------
// Page builders
// ---------------------------------------------------------------------------

void DesgranaWindow::buildIdlePage() {
    m_idlePage = new QWidget;

    auto *iconLabel = new QLabel;
    const QIcon appIcon = QIcon::fromTheme("desgrana",
        QIcon::fromTheme("folder-open",
            qApp->style()->standardIcon(QStyle::SP_DirOpenIcon)));
    iconLabel->setPixmap(appIcon.pixmap(48, 48));
    iconLabel->setAlignment(Qt::AlignCenter);
    iconLabel->setStyleSheet("QLabel { border: none; background: transparent; }");

    auto *line1 = new QLabel("Drop a session folder here");
    line1->setAlignment(Qt::AlignCenter);
    line1->setStyleSheet("QLabel { border: none; }");
    {
        QFont f = line1->font();
        f.setPixelSize(20);
        line1->setFont(f);
    }

    auto *line2 = new QLabel("with .wav, .bin, .snap files");
    line2->setAlignment(Qt::AlignCenter);
    line2->setStyleSheet("QLabel { border: none; }");
    line2->setForegroundRole(QPalette::PlaceholderText);

    m_idleErrorLabel = new QLabel;
    m_idleErrorLabel->setAlignment(Qt::AlignCenter);
    m_idleErrorLabel->setWordWrap(true);
    m_idleErrorLabel->setStyleSheet("QLabel { color: #FF3B30; border: none; }");
    {
        QFont f = m_idleErrorLabel->font();
        f.setPixelSize(12);
        m_idleErrorLabel->setFont(f);
    }
    m_idleErrorLabel->setVisible(false);

    // Object name scopes the border stylesheet to this frame only,
    // preventing inheritance by child QLabel (which also derives from QFrame).
    // Stylesheet applied dynamically in applyDynamicStyles() to use QPalette colors.
    m_dropZoneFrame = new QFrame;
    m_dropZoneFrame->setObjectName("dropZone");

    auto *dzLayout = new QVBoxLayout(m_dropZoneFrame);
    dzLayout->setAlignment(Qt::AlignCenter);
    dzLayout->setSpacing(8);
    dzLayout->setContentsMargins(24, 24, 24, 24);
    dzLayout->addWidget(iconLabel);
    dzLayout->addWidget(line1);
    dzLayout->addWidget(line2);
    dzLayout->addSpacing(8);
    dzLayout->addWidget(m_idleErrorLabel);

    auto *layout = new QVBoxLayout(m_idlePage);
    layout->setContentsMargins(20, 16, 20, 16);
    layout->setSpacing(0);
    layout->addWidget(m_dropZoneFrame);
    // No addStretch() — idle page must stay compact for dynamic window sizing.
}

void DesgranaWindow::buildReadyPage() {
    m_readyPage = new QWidget;

    // Top row: editable session name + clear button
    m_sessionNameEdit = new QLineEdit;
    m_sessionNameEdit->setPlaceholderText("Session name");
    {
        QFont f = m_sessionNameEdit->font();
        f.setPixelSize(17);
        f.setWeight(QFont::DemiBold);
        m_sessionNameEdit->setFont(f);
    }
    // Base stylesheet: no border; hover border applied dynamically in applyDynamicStyles().
    m_sessionNameEdit->setStyleSheet(
        "QLineEdit { border: none; background: transparent; padding: 2px 0; }");
    connect(m_sessionNameEdit, &QLineEdit::textChanged,
            this, &DesgranaWindow::onSessionNameChanged);

    auto *resetBtn = new QPushButton("Clear session");
    connect(resetBtn, &QPushButton::clicked, this, [this]() { showIdle(); });

    auto *topRow = new QHBoxLayout;
    topRow->setContentsMargins(0, 0, 0, 0);
    topRow->addWidget(m_sessionNameEdit, 1);
    topRow->addSpacing(8);
    topRow->addWidget(resetBtn);

    // Hint below the name
    auto *warningLabel = new QLabel("Make sure your tracks are grouped as expected below:");
    warningLabel->setForegroundRole(QPalette::PlaceholderText);
    {
        QFont f = warningLabel->font();
        f.setPixelSize(11);
        warningLabel->setFont(f);
    }
    warningLabel->setWordWrap(true);

    // Channel list — plain QScrollArea so row widgets get real Enter/Leave events.
    m_channelContainer = nullptr;
    m_channelScroll = new QScrollArea;
    m_channelScroll->setWidgetResizable(true);
    m_channelScroll->setFrameShape(QFrame::NoFrame);
    m_channelScroll->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);

    // Output folder — full-width editable path
    auto *outputSep = new QFrame;
    outputSep->setFixedHeight(16);

    auto *outputLabel = new QLabel("Output folder");
    outputLabel->setForegroundRole(QPalette::PlaceholderText);
    {
        QFont f = outputLabel->font();
        f.setPixelSize(11);
        outputLabel->setFont(f);
    }

    m_outputEdit = new QLineEdit;
    m_outputEdit->setPlaceholderText("Output directory");
    connect(m_outputEdit, &QLineEdit::textChanged, this, &DesgranaWindow::checkOutputExists);

    m_outputWarningLabel = new QLabel("This folder already exists \xe2\x80\x94 files may be overwritten.");
    m_outputWarningLabel->setStyleSheet("QLabel { color: #FF9500; }");
    {
        QFont f = m_outputWarningLabel->font();
        f.setPixelSize(11);
        m_outputWarningLabel->setFont(f);
    }
    m_outputWarningLabel->setWordWrap(true);
    m_outputWarningLabel->setVisible(false);

    // Bottom row: browse (left) + extract (right), mirroring macOS layout
    m_browseBtn = new QPushButton("Choose a different folder\xe2\x80\xa6");
    connect(m_browseBtn, &QPushButton::clicked, this, &DesgranaWindow::browseOutput);

    m_splitBtn = new QPushButton("Extract");
    // Colors applied dynamically in applyDynamicStyles() to use QPalette::Highlight.
    m_splitBtn->setStyleSheet(
        "QPushButton { border-radius: 4px; padding: 6px 20px; font-weight: bold; }");
    connect(m_splitBtn, &QPushButton::clicked, this, &DesgranaWindow::startSplit);

    auto *btnRow = new QHBoxLayout;
    btnRow->setContentsMargins(0, 0, 0, 0);
    btnRow->addWidget(m_browseBtn);
    btnRow->addStretch();
    btnRow->addWidget(m_splitBtn);

    auto *layout = new QVBoxLayout(m_readyPage);
    layout->setContentsMargins(20, 12, 20, 16);
    layout->setSpacing(6);
    layout->addLayout(topRow);
    layout->addWidget(warningLabel);
    layout->addSpacing(4);
    layout->addWidget(m_channelScroll);
    layout->addWidget(outputSep);
    layout->addWidget(outputLabel);
    layout->addWidget(m_outputEdit);
    layout->addWidget(m_outputWarningLabel);
    layout->addSpacing(12);
    layout->addLayout(btnRow);
}

void DesgranaWindow::buildSplittingPage() {
    m_splittingPage = new QWidget;

    m_splittingLabel = new QLabel("Extracting\xe2\x80\xa6");
    m_splittingLabel->setAlignment(Qt::AlignCenter);
    {
        QFont f = m_splittingLabel->font();
        f.setPixelSize(20);
        m_splittingLabel->setFont(f);
    }

    m_progress = new QProgressBar;
    m_progress->setRange(0, 0);
    m_progress->setTextVisible(false);

    auto *layout = new QVBoxLayout(m_splittingPage);
    layout->setContentsMargins(32, 24, 32, 24);
    layout->setSpacing(0);
    layout->addWidget(m_splittingLabel);
    layout->addSpacing(16);
    layout->addWidget(m_progress);
    layout->addSpacing(16);
}

void DesgranaWindow::buildDonePage() {
    m_donePage = new QWidget;

    m_summaryLabel = new QLabel;
    m_summaryLabel->setAlignment(Qt::AlignCenter);
    m_summaryLabel->setWordWrap(true);
    {
        QFont f = m_summaryLabel->font();
        f.setPixelSize(20);
        m_summaryLabel->setFont(f);
    }

    m_openDirBtn = new QPushButton("Open output folder");
    m_openDirBtn->setStyleSheet(
        "QPushButton { border-radius: 4px; padding: 6px 20px; font-weight: bold; }");
    connect(m_openDirBtn, &QPushButton::clicked, this, [this]() {
        QDesktopServices::openUrl(QUrl::fromLocalFile(m_lastOutputPath));
    });

    auto *newSessionBtn = new QPushButton("New session");
    newSessionBtn->setStyleSheet(
        "QPushButton { border-radius: 4px; padding: 6px 20px; }");
    connect(newSessionBtn, &QPushButton::clicked, this, [this]() { showIdle(); });

    auto *btnRow = new QHBoxLayout;
    btnRow->setAlignment(Qt::AlignCenter);
    btnRow->setSpacing(12);
    btnRow->addWidget(m_openDirBtn);
    btnRow->addWidget(newSessionBtn);

    auto *layout = new QVBoxLayout(m_donePage);
    layout->setContentsMargins(32, 24, 32, 24);
    layout->setSpacing(0);
    layout->addWidget(m_summaryLabel);
    layout->addSpacing(16);
    layout->addLayout(btnRow);
}

// ---------------------------------------------------------------------------
// State transitions
// ---------------------------------------------------------------------------

void DesgranaWindow::switchToPage(int index) {
    QWidget *pages[] = {m_idlePage, m_readyPage, m_splittingPage, m_donePage};
    // Release channel scroll fixed height before hiding the ready page so that
    // its layout minimum doesn't stay large while hidden.
    if (m_currentPage == 1 && index != 1 && m_channelScroll) {
        m_channelScroll->setMinimumHeight(0);
        m_channelScroll->setMaximumHeight(QWIDGETSIZE_MAX);
    }
    if (m_currentPage >= 0) pages[m_currentPage]->hide();
    pages[index]->show();
    m_currentPage = index;
    setMinimumHeight(0);
    adjustSize();
}

void DesgranaWindow::showIdle(const QString &error) {
    const bool hasError = !error.isEmpty();
    m_idleErrorLabel->setText(error);
    m_idleErrorLabel->setVisible(hasError);
    m_dropZoneFrame->setStyleSheet(hasError
        ? dropZoneErrorStyle()
        : dropZoneIdleStyle(palette()));
    switchToPage(0);
}

void DesgranaWindow::showReady() {
    m_sessionNameEdit->setText(m_sessionName);
    populateChannelList();
    const int stereo = static_cast<int>(m_effectivePairs.size());
    const int rows   = m_channels - stereo; // mono rows + stereo rows
    m_channelScroll->setFixedHeight(qMin(rows, 8) * 30);
    updateOutputPath();
    switchToPage(1);
}

void DesgranaWindow::showSplitting() {
    m_progress->setRange(0, 0);
    m_progress->setValue(0);
    m_splittingLabel->setText("Extracting\xe2\x80\xa6");
    switchToPage(2);
}

void DesgranaWindow::showDone() {
    const int stereo = static_cast<int>(m_effectivePairs.size());
    const int mono   = m_channels - 2 * stereo;
    const int total  = mono + stereo;

    QStringList parts;
    if (stereo > 0) parts << QString("%1 stereo").arg(stereo);
    if (mono   > 0) parts << QString("%1 mono").arg(mono);

    m_summaryLabel->setText(
        QString("%1 file%2 extracted\n%3")
            .arg(total)
            .arg(total != 1 ? "s" : "")
            .arg(parts.join(", ")));

    switchToPage(3);
}

// ---------------------------------------------------------------------------
// Drag and drop
// ---------------------------------------------------------------------------

void DesgranaWindow::dragEnterEvent(QDragEnterEvent *e) {
    if (!e->mimeData()->hasUrls()) return;
    e->acceptProposedAction();
    if (m_currentPage == 0)
        m_dropZoneFrame->setStyleSheet(dropZoneTargetedStyle(palette()));
}

void DesgranaWindow::dragLeaveEvent(QDragLeaveEvent *) {
    if (m_currentPage == 0)
        m_dropZoneFrame->setStyleSheet(m_idleErrorLabel->isVisible()
            ? dropZoneErrorStyle()
            : dropZoneIdleStyle(palette()));
}

void DesgranaWindow::dropEvent(QDropEvent *e) {
    const auto urls = e->mimeData()->urls();
    if (urls.isEmpty()) return;
    const QString path = urls.first().toLocalFile();
    if (QDir(path).exists()) loadSession(path);
}

// ---------------------------------------------------------------------------
// Session loading
// ---------------------------------------------------------------------------

void DesgranaWindow::loadSession(const QString &path) {
    char sceneName[256] = {};
    char err[512]       = {};
    int32_t channels    = 0;
    double  duration    = 0;

    int rc = desgrana_probe(
        path.toUtf8().constData(),
        &channels, &duration,
        sceneName, sizeof(sceneName),
        m_pairLefts,  m_pairRights,  kSnapCap, &m_pairCount,
        m_chKeys,     &m_chNames[0][0], kSnapCap, &m_chCount,
        err, sizeof(err)
    );

    if (rc != 0) {
        showIdle(QString::fromUtf8(err));
        return;
    }

    m_sessionPath = path;
    m_channels    = channels;
    m_duration    = duration;

    m_effectivePairs.clear();
    for (int i = 0; i < m_pairCount; i++)
        m_effectivePairs.push_back({m_pairLefts[i], m_pairRights[i]});

    m_sessionName = *sceneName ? QString::fromUtf8(sceneName) : QDir(path).dirName();
    showReady();
}

void DesgranaWindow::onSessionNameChanged(const QString &name) {
    m_sessionName = name;
    updateOutputPath();
}

void DesgranaWindow::updateOutputPath() {
    const QString desktop = QStandardPaths::writableLocation(QStandardPaths::DesktopLocation);
    m_outputEdit->setText(QDir(desktop).filePath(
        m_sessionName.trimmed().replace(' ', '_')));
    checkOutputExists();
}

void DesgranaWindow::checkOutputExists() {
    const bool exists = QDir(m_outputEdit->text()).exists();
    m_outputWarningLabel->setVisible(exists);
    adjustSize();
}

void DesgranaWindow::browseOutput() {
    const QString dir = QFileDialog::getExistingDirectory(
        this, "Output directory", m_outputEdit->text());
    if (!dir.isEmpty()) m_outputEdit->setText(dir);
}

// ---------------------------------------------------------------------------
// Extraction
// ---------------------------------------------------------------------------

void DesgranaWindow::startSplit() {
    if (m_sessionPath.isEmpty()) return;

    m_lastOutputPath = m_outputEdit->text();
    showSplitting();

    SplitWorker::Params p;
    p.sessionPath = m_sessionPath;
    p.outputPath  = m_lastOutputPath;
    if (!m_useShortNames) {
        const QString name = m_sessionName.isEmpty()
            ? QDir(p.outputPath).dirName() : m_sessionName;
        p.prefix = name.trimmed().replace(' ', '_') + "_";
    }
    for (const auto &pr : m_effectivePairs) {
        p.pairLefts.push_back(pr.first);
        p.pairRights.push_back(pr.second);
    }
    p.chKeys.assign(m_chKeys, m_chKeys + m_chCount);
    for (int i = 0; i < m_chCount; i++) p.chNames.push_back(m_chNames[i]);

    auto *thread = new QThread(this);
    auto *worker = new SplitWorker(std::move(p));
    worker->moveToThread(thread);

    connect(thread, &QThread::started,   worker, &SplitWorker::run);
    connect(worker, &SplitWorker::progress, this, &DesgranaWindow::onProgress);
    connect(worker, &SplitWorker::done,  this, &DesgranaWindow::onSplitDone);
    connect(worker, &SplitWorker::error, this, &DesgranaWindow::onSplitError);
    connect(worker, &SplitWorker::done,  thread, &QThread::quit);
    connect(worker, &SplitWorker::error, thread, &QThread::quit);
    connect(thread, &QThread::finished,  worker, &QObject::deleteLater);
    connect(thread, &QThread::finished,  thread, &QObject::deleteLater);

    thread->start();
}

void DesgranaWindow::onProgress(int take, int total) {
    if (total > 1) {
        m_progress->setRange(0, total);
        m_progress->setValue(take);
        m_splittingLabel->setText(QString("Take %1 / %2").arg(take).arg(total));
    }
}

void DesgranaWindow::onSplitDone() {
    showDone();
}

void DesgranaWindow::onSplitError(const QString &msg) {
    showIdle(msg);
}

// ---------------------------------------------------------------------------
// Channel list
// ---------------------------------------------------------------------------

void DesgranaWindow::populateChannelList() {
    // Replace the scroll area's widget — QScrollArea deletes the old one.
    m_rowWidgets.clear();
    auto *container = new QWidget;
    m_channelScroll->setWidget(container);
    m_channelContainer = container;

    auto *vbox = new QVBoxLayout(container);
    vbox->setContentsMargins(0, 0, 0, 0);
    vbox->setSpacing(0);

    std::map<int, QString> names;
    for (int i = 0; i < m_chCount; i++)
        names[m_chKeys[i]] = QString::fromUtf8(m_chNames[i]);

    std::map<int, int> pairOf;
    std::set<int>      inPair;
    for (const auto &pr : m_effectivePairs) {
        pairOf[pr.first] = pr.second;
        inPair.insert(pr.first);
        inPair.insert(pr.second);
    }

    auto isLinkable = [&](int ch) {
        if (inPair.count(ch)) return false;
        return (ch > 1 && !inPair.count(ch - 1)) || (ch < m_channels && !inPair.count(ch + 1));
    };

    std::set<int> emitted;
    for (int ch = 1; ch <= m_channels; ch++) {
        if (emitted.count(ch)) continue;

        auto *row  = new QWidget;
        auto *hbox = new QHBoxLayout(row);
        hbox->setContentsMargins(4, 3, 4, 3);
        hbox->setSpacing(8);

        auto *badge = new QLabel;
        auto *name  = new QLabel;
        auto *chNum = new QLabel;

        badge->setFixedWidth(42);
        badge->setAlignment(Qt::AlignLeft | Qt::AlignVCenter);
        badge->setForegroundRole(QPalette::PlaceholderText);

        chNum->setAlignment(Qt::AlignRight | Qt::AlignVCenter);
        {
            QColor tertiary = palette().color(QPalette::WindowText);
            tertiary.setAlphaF(0.40);
            auto p = chNum->palette();
            p.setColor(QPalette::WindowText, tertiary);
            chNum->setPalette(p);
        }

        {
            QFont mono("Monospace");
            mono.setStyleHint(QFont::Monospace);
            mono.setPixelSize(12);
            badge->setFont(mono);
            chNum->setFont(mono);
        }

        bool isStereo = pairOf.count(ch) > 0;
        if (isStereo) {
            const int r = pairOf[ch];
            emitted.insert(ch); emitted.insert(r);

            badge->setText("stereo");

            const QString lName = names.count(ch) ? names[ch] : QString();
            const QString rName = names.count(r)  ? names[r]  : QString();
            if (!lName.isEmpty() && !rName.isEmpty())
                name->setText(lName + " & " + rName);
            else if (!lName.isEmpty())
                name->setText(lName);
            else
                name->setText(QString("ch %1-%2").arg(ch).arg(r));

            chNum->setText(QString("ch %1-%2")
                .arg(ch, 2, 10, QChar('0')).arg(r, 2, 10, QChar('0')));

            row->setProperty("ch",       ch);
            row->setProperty("isStereo", 1);
            row->setProperty("partner",  0);
            row->setCursor(Qt::PointingHandCursor);
            name->setToolTip("Click to split to mono");
            m_rowWidgets[ch] = row;
        } else {
            emitted.insert(ch);
            badge->setText("mono");
            name->setText(names.count(ch) ? names[ch] : QString("ch %1").arg(ch));
            chNum->setText(QString("ch %1").arg(ch, 2, 10, QChar('0')));

            const bool linkable = isLinkable(ch);
            int partner = 0;
            if (linkable) {
                if (ch < m_channels && !inPair.count(ch + 1)) partner = ch + 1;
                else if (ch > 1    && !inPair.count(ch - 1)) partner = ch - 1;
            }
            row->setProperty("ch",       ch);
            row->setProperty("isStereo", 0);
            row->setProperty("partner",  partner);
            if (linkable) {
                row->setCursor(Qt::PointingHandCursor);
                name->setToolTip("Click to pair with adjacent channel");
            }
            m_rowWidgets[ch] = row;
        }


        row->installEventFilter(this);

        hbox->addWidget(badge);
        hbox->addWidget(name, 1);
        hbox->addWidget(chNum);

        vbox->addWidget(row);
    }

    vbox->addStretch();
}

bool DesgranaWindow::eventFilter(QObject *obj, QEvent *event) {
    auto *w = qobject_cast<QWidget *>(obj);
    if (w && w->parent() == m_channelContainer) {
        if (event->type() == QEvent::Enter) {
            QColor hoverColor = palette().color(QPalette::Highlight);
            hoverColor.setAlphaF(0.06);
            auto applyHover = [hoverColor](QWidget *w) {
                w->setAutoFillBackground(true);
                auto pal = w->palette();
                pal.setColor(QPalette::Window, hoverColor);
                w->setPalette(pal);
            };
            applyHover(w);
            const int partner = w->property("partner").toInt();
            if (partner > 0 && m_rowWidgets.count(partner))
                applyHover(m_rowWidgets[partner]);
            return false;
        }
        if (event->type() == QEvent::Leave) {
            w->setAutoFillBackground(false);
            const int partner = w->property("partner").toInt();
            if (partner > 0 && m_rowWidgets.count(partner))
                m_rowWidgets[partner]->setAutoFillBackground(false);
            return false;
        }
        if (event->type() == QEvent::MouseButtonPress) {
            handleChannelRowClick(w);
            return true;
        }
    }
    return QWidget::eventFilter(obj, event);
}

void DesgranaWindow::handleChannelRowClick(QWidget *row) {
    const int ch        = row->property("ch").toInt();
    const bool isStereo = row->property("isStereo").toInt() == 1;

    if (isStereo) {
        m_effectivePairs.erase(
            std::remove_if(m_effectivePairs.begin(), m_effectivePairs.end(),
                [ch](const std::pair<int,int> &p){ return p.first == ch; }),
            m_effectivePairs.end());
    } else {
        std::set<int> inPair;
        for (const auto &pr : m_effectivePairs) {
            inPair.insert(pr.first); inPair.insert(pr.second);
        }
        if (inPair.count(ch)) return;
        for (int delta : {1, -1}) {
            const int nb = ch + delta;
            if (nb >= 1 && nb <= m_channels && !inPair.count(nb)) {
                const int l = std::min(ch, nb), r = std::max(ch, nb);
                m_effectivePairs.push_back({l, r});
                std::sort(m_effectivePairs.begin(), m_effectivePairs.end());
                break;
            }
        }
    }

    populateChannelList();

    const int stereo = static_cast<int>(m_effectivePairs.size());
    const int rows   = m_channels - stereo;
    m_channelScroll->setFixedHeight(qMin(rows, 8) * 30);
    adjustSize();
}

// ---------------------------------------------------------------------------
// Update check
// ---------------------------------------------------------------------------

static QString platformOSV() {
    QFile f("/etc/os-release");
    if (!f.open(QIODevice::ReadOnly)) return "linux";
    QString id = "linux", version;
    for (const QByteArray &line : f.readAll().split('\n')) {
        const auto parts = QString::fromUtf8(line).split('=');
        if (parts.size() < 2) continue;
        const QString key = parts[0];
        const QString val = QString(parts[1]).remove('"');
        if (key == "ID")         id      = val;
        if (key == "VERSION_ID") version = val.split('.').first();
    }
    return id + version;
}

static bool isNewerVersion(const QString &latest, const QString &current) {
    auto parse = [](const QString &v) {
        QList<int> parts;
        for (const auto &p : v.split('.')) parts << p.toInt();
        while (parts.size() < 3) parts << 0;
        return parts;
    };
    const auto l = parse(latest), c = parse(current);
    for (int i = 0; i < 3; i++) {
        if (l[i] > c[i]) return true;
        if (l[i] < c[i]) return false;
    }
    return false;
}

void DesgranaWindow::checkForUpdate() {
    QSettings s("desgrana", "desgrana");
    if (!s.value("updateCheck/enabled", true).toBool()) return;

    const int intervalDays = s.value("updateCheck/intervalDays", 30).toInt();
    const qint64 lastCheck = s.value("updateCheck/lastTimestamp", 0LL).toLongLong();
    const qint64 now       = QDateTime::currentSecsSinceEpoch();
    if (now - lastCheck < static_cast<qint64>(intervalDays) * 86400) return;

    s.setValue("updateCheck/lastTimestamp", now);

    QUrl url("https://romaindalverny.com/atelier/desgrana/version.json");
    QUrlQuery q;
    q.addQueryItem("os",   "linux");
    q.addQueryItem("osv",  platformOSV());
    q.addQueryItem("arch", QSysInfo::currentCpuArchitecture());
    q.addQueryItem("v",    DESGRANA_VERSION);
    q.addQueryItem("l",    QLocale::system().name().section('_', 0, 0));
    url.setQuery(q);

    m_nam->get(QNetworkRequest(url));
}

void DesgranaWindow::onUpdateReply(QNetworkReply *reply) {
    reply->deleteLater();
    if (reply->error() != QNetworkReply::NoError) return;

    const QJsonObject json = QJsonDocument::fromJson(reply->readAll()).object();
    const QString latest   = json["version"].toString();
    const QString url      = json["url"].toString();

    if (latest.isEmpty() || !isNewerVersion(latest, DESGRANA_VERSION)) return;

    const QString link = url.isEmpty()
        ? latest
        : QString("<a href=\"%1\">%2</a>").arg(url, latest);
    m_updateLabel->setText(QString("Update available: %1").arg(link));
    m_updateLabel->setVisible(true);
}

// ---------------------------------------------------------------------------
// Dynamic styling (palette-aware)
// ---------------------------------------------------------------------------

void DesgranaWindow::applyDynamicStyles() {
    const QPalette pal = palette();

    // Drop zone -- re-apply the current state's stylesheet with updated colors.
    if (m_currentPage == 0)
        m_dropZoneFrame->setStyleSheet(m_idleErrorLabel->isVisible()
            ? dropZoneErrorStyle()
            : dropZoneIdleStyle(pal));

    // Extract button -- QPalette::Highlight as background.
    {
        const QColor bg     = pal.color(QPalette::Highlight);
        const QColor fg     = pal.color(QPalette::HighlightedText);
        const QColor bgHov  = bg.darker(115);
        m_splitBtn->setStyleSheet(
            QString("QPushButton { background: %1; color: %2; border-radius: 4px;"
                    "              padding: 6px 20px; font-weight: bold; }"
                    "QPushButton:hover { background: %3; }")
                .arg(bg.name(), fg.name(), bgHov.name()));
    }

    // Session name field -- no default border; QPalette::PlaceholderText at 22%
    // opacity on hover.
    {
        QColor hoverBorder = pal.color(QPalette::PlaceholderText);
        hoverBorder.setAlphaF(0.22);
        m_sessionNameEdit->setStyleSheet(
            QString("QLineEdit { border: none; background: transparent; padding: 2px 0; }"
                    "QLineEdit:hover { border: 1px solid %1; border-radius: 5px; }")
                .arg(paletteRgba(hoverBorder)));
    }

    // Update label -- let the <a href> element inherit QPalette::Link; no color override needed.
}

void DesgranaWindow::changeEvent(QEvent *e) {
    if (e->type() == QEvent::PaletteChange)
        applyDynamicStyles();
    QWidget::changeEvent(e);
}
