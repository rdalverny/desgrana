// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
#include "DesgranaWindow.hpp"
#include "include/desgrana_bridge.h"

#include <QDragEnterEvent>
#include <QDropEvent>
#include <QMimeData>
#include <QFileDialog>
#include <QHBoxLayout>
#include <QVBoxLayout>
#include <QThread>
#include <QDir>
#include <QStandardPaths>

// ---------------------------------------------------------------------------
// Worker: runs desgrana_split on a background thread
// ---------------------------------------------------------------------------

class SplitWorker : public QObject {
    Q_OBJECT
public:
    struct Params {
        QString sessionPath;
        QString outputPath;
        QString prefix;
        // TODO: expose stereo pairs and channel names from SnapInfo
    };

    explicit SplitWorker(Params p, QObject *parent = nullptr)
        : QObject(parent), m_params(std::move(p)) {}

public slots:
    void run() {
        char err[512] = {};
        int rc = desgrana_split(
            m_params.sessionPath.toUtf8().constData(),
            m_params.outputPath.toUtf8().constData(),
            m_params.prefix.isEmpty() ? nullptr : m_params.prefix.toUtf8().constData(),
            nullptr, nullptr, 0,   // stereo pairs (none for now)
            nullptr, nullptr, 0,   // channel names (none for now)
            [](int32_t take, int32_t total, void *ud) {
                auto *w = static_cast<SplitWorker *>(ud);
                emit w->progress(take, total);
            },
            this,
            err, sizeof(err)
        );
        if (rc == 0)
            emit done();
        else
            emit error(QString::fromUtf8(err));
    }

signals:
    void progress(int take, int total);
    void done();
    void error(const QString &msg);

private:
    Params m_params;
};

#include "DesgranaWindow.moc"

// ---------------------------------------------------------------------------
// DesgranaWindow
// ---------------------------------------------------------------------------

DesgranaWindow::DesgranaWindow(QWidget *parent) : QWidget(parent) {
    setWindowTitle("Desgrana");
    setMinimumWidth(520);
    setAcceptDrops(true);

    // Drop zone
    m_dropZone = new QFrame(this);
    m_dropZone->setFrameShape(QFrame::StyledPanel);
    m_dropZone->setMinimumHeight(120);
    m_dropLabel = new QLabel("Drop a session folder here", m_dropZone);
    m_dropLabel->setAlignment(Qt::AlignCenter);
    auto *dropLayout = new QVBoxLayout(m_dropZone);
    dropLayout->addWidget(m_dropLabel);

    // Info
    m_infoLabel = new QLabel(this);
    m_infoLabel->setAlignment(Qt::AlignCenter);

    // Output path row
    m_outputEdit = new QLineEdit(this);
    m_outputEdit->setPlaceholderText("Output directory");
    m_browseBtn = new QPushButton("Browse…", this);
    connect(m_browseBtn, &QPushButton::clicked, this, &DesgranaWindow::browseOutput);
    auto *outputRow = new QHBoxLayout;
    outputRow->addWidget(m_outputEdit);
    outputRow->addWidget(m_browseBtn);

    // Split button
    m_splitBtn = new QPushButton("Split", this);
    m_splitBtn->setEnabled(false);
    connect(m_splitBtn, &QPushButton::clicked, this, &DesgranaWindow::startSplit);

    // Progress + status
    m_progress = new QProgressBar(this);
    m_progress->setRange(0, 100);
    m_progress->setVisible(false);

    m_statusLabel = new QLabel(this);
    m_statusLabel->setAlignment(Qt::AlignCenter);

    auto *layout = new QVBoxLayout(this);
    layout->setContentsMargins(16, 16, 16, 16);
    layout->setSpacing(10);
    layout->addWidget(m_dropZone);
    layout->addWidget(m_infoLabel);
    layout->addLayout(outputRow);
    layout->addWidget(m_splitBtn);
    layout->addWidget(m_progress);
    layout->addWidget(m_statusLabel);
}

// ---------------------------------------------------------------------------
// Drag and drop
// ---------------------------------------------------------------------------

void DesgranaWindow::dragEnterEvent(QDragEnterEvent *e) {
    if (e->mimeData()->hasUrls()) e->acceptProposedAction();
}

void DesgranaWindow::dropEvent(QDropEvent *e) {
    const auto urls = e->mimeData()->urls();
    if (urls.isEmpty()) return;
    const QString path = urls.first().toLocalFile();
    if (QDir(path).exists()) loadSession(path);
}

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
        err, sizeof(err)
    );

    if (rc != 0) {
        m_statusLabel->setText(QString("Error: %1").arg(QString::fromUtf8(err)));
        setReady(false);
        return;
    }

    m_sessionPath = path;
    m_channels    = channels;
    m_duration    = duration;

    const QString name = *sceneName ? QString::fromUtf8(sceneName)
                                    : QDir(path).dirName();
    m_dropLabel->setText(name);
    m_infoLabel->setText(QString("%1 ch  •  %2 s")
        .arg(channels)
        .arg(duration, 0, 'f', 1));

    // Default output: Desktop/<name>
    const QString desktop = QStandardPaths::writableLocation(QStandardPaths::DesktopLocation);
    m_outputEdit->setText(QDir(desktop).filePath(
        name.trimmed().replace(' ', '_')));

    m_statusLabel->clear();
    setReady(true);
}

void DesgranaWindow::setReady(bool ready) {
    m_splitBtn->setEnabled(ready);
    m_progress->setVisible(false);
}

void DesgranaWindow::browseOutput() {
    const QString dir = QFileDialog::getExistingDirectory(
        this, "Output directory", m_outputEdit->text());
    if (!dir.isEmpty()) m_outputEdit->setText(dir);
}

void DesgranaWindow::startSplit() {
    if (m_sessionPath.isEmpty()) return;

    m_splitBtn->setEnabled(false);
    m_progress->setValue(0);
    m_progress->setVisible(true);
    m_statusLabel->clear();

    SplitWorker::Params p;
    p.sessionPath = m_sessionPath;
    p.outputPath  = m_outputEdit->text();
    // prefix = "<name>_" unless output dir name matches session name
    p.prefix = QDir(p.outputPath).dirName() + "_";

    auto *thread = new QThread(this);
    auto *worker = new SplitWorker(std::move(p));
    worker->moveToThread(thread);

    connect(thread, &QThread::started, worker, &SplitWorker::run);
    connect(worker, &SplitWorker::progress, this, &DesgranaWindow::onProgress);
    connect(worker, &SplitWorker::done,     this, &DesgranaWindow::onDone);
    connect(worker, &SplitWorker::error,    this, &DesgranaWindow::onError);
    connect(worker, &SplitWorker::done,  thread, &QThread::quit);
    connect(worker, &SplitWorker::error, thread, &QThread::quit);
    connect(thread, &QThread::finished, worker, &QObject::deleteLater);
    connect(thread, &QThread::finished, thread, &QObject::deleteLater);

    thread->start();
}

void DesgranaWindow::onProgress(int take, int total) {
    if (total > 0) m_progress->setValue(take * 100 / total);
}

void DesgranaWindow::onDone() {
    m_progress->setValue(100);
    m_statusLabel->setText(QString("Done — files written to %1").arg(m_outputEdit->text()));
    setReady(true);
}

void DesgranaWindow::onError(const QString &msg) {
    m_progress->setVisible(false);
    m_statusLabel->setText("Error: " + msg);
    setReady(true);
}
