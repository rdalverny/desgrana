// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
#include "Preferences.hpp"
#include "include/desgrana_bridge.h"

#include <QCheckBox>
#include <QComboBox>
#include <QDialogButtonBox>
#include <QDir>
#include <QFileDialog>
#include <QHBoxLayout>
#include <QLabel>
#include <QPushButton>
#include <QSettings>
#include <QStandardPaths>
#include <QVBoxLayout>

static const char* kShortNames              = "output/shortNames";
static const char* kCustomOutputDir         = "output/customDir";
static const char* kWriteReport             = "report/enabled";
static const char* kUpdateCheckEnabled      = "updateCheck/enabled";
static const char* kUpdateCheckIntervalDays = "updateCheck/intervalDays";
static const char* kUpdateCheckLastTs       = "updateCheck/lastTimestamp";

static constexpr bool kDefaultShortNames  = true;
static constexpr bool kDefaultWriteReport = false;

static constexpr int kHintPixelSize = 11;

struct IntervalChoice { int days; const char *label; };
static const IntervalChoice kIntervals[] = {
    {7,   "Week"},
    {30,  "Month"},
    {180, "6 months"},
};

// ---------------------------------------------------------------------------
// Prefs
// ---------------------------------------------------------------------------

namespace Prefs {

bool shortNames() {
    return QSettings().value(kShortNames, kDefaultShortNames).toBool();
}

void setShortNames(bool on) {
    QSettings().setValue(kShortNames, on);
}

bool writeReport() {
    return QSettings().value(kWriteReport, kDefaultWriteReport).toBool();
}

void setWriteReport(bool on) {
    QSettings().setValue(kWriteReport, on);
}

QString customOutputDir() {
    return QSettings().value(kCustomOutputDir).toString();
}

void setCustomOutputDir(const QString &dir) {
    QSettings s;
    if (dir.isEmpty()) {
        s.remove(kCustomOutputDir);
        return;
    }
    s.setValue(kCustomOutputDir, dir);
}

int32_t updateEnabledSetting() {
    QSettings s;
    if (!s.contains(kUpdateCheckEnabled)) {
        return DESGRANA_UNSET;
    }
    return s.value(kUpdateCheckEnabled).toBool() ? 1 : 0;
}

int32_t updateIntervalSetting() {
    QSettings s;
    if (!s.contains(kUpdateCheckIntervalDays)) {
        return DESGRANA_UNSET;
    }
    return s.value(kUpdateCheckIntervalDays).toInt();
}

bool updateEnabled() {
    const int32_t stored = updateEnabledSetting();
    if (stored != DESGRANA_UNSET) {
        return stored != 0;
    }

    int32_t enabled = 0, interval = 0;
    desgrana_update_defaults(&enabled, &interval);
    return enabled != 0;
}

void setUpdateEnabled(bool on) {
    QSettings().setValue(kUpdateCheckEnabled, on);
}

int updateIntervalDays() {
    const int32_t stored = updateIntervalSetting();
    if (stored != DESGRANA_UNSET) {
        return stored;
    }

    int32_t enabled = 0, interval = 0;
    desgrana_update_defaults(&enabled, &interval);
    return interval;
}

void setUpdateIntervalDays(int days) {
    QSettings().setValue(kUpdateCheckIntervalDays, days);
}

qint64 lastUpdateCheck() {
    return QSettings().value(kUpdateCheckLastTs, 0LL).toLongLong();
}

void setLastUpdateCheck(qint64 epoch) {
    QSettings().setValue(kUpdateCheckLastTs, epoch);
}

// Update keys are removed rather than overwritten, so the installer's machine
// default and Core's defaults apply again.
void resetToDefaults() {
    QSettings s;
    s.remove(kShortNames);
    s.remove(kWriteReport);
    s.remove(kCustomOutputDir);
    s.remove(kUpdateCheckEnabled);
    s.remove(kUpdateCheckIntervalDays);
}

} // namespace Prefs

// ---------------------------------------------------------------------------
// PreferencesDialog
// ---------------------------------------------------------------------------

static QLabel *makeHint(const QString &text = {}) {
    auto *label = new QLabel(text);
    label->setWordWrap(true);
    label->setForegroundRole(QPalette::PlaceholderText);

    QFont f = label->font();
    f.setPixelSize(kHintPixelSize);
    label->setFont(f);

    return label;
}

PreferencesDialog::PreferencesDialog(QWidget *parent) : QDialog(parent) {
    setWindowTitle("Preferences");
    setMinimumWidth(460);

    m_shortNames = new QCheckBox("Use short filenames");
    m_shortNamesHint = makeHint();

    m_report = new QCheckBox("Write JSON report");
    auto *reportHint = makeHint(
        "Saves report.json in the output folder: formats, takes, chosen "
        "extractions, markers and skipped tracks (for tools and AI agents).");

    m_outputDir = new QLabel;
    m_outputDir->setTextInteractionFlags(Qt::TextSelectableByMouse);
    auto *chooseBtn = new QPushButton("Choose\xe2\x80\xa6");
    m_resetOutputBtn = new QPushButton("Reset to default");

    auto *outputRow = new QHBoxLayout;
    outputRow->addWidget(chooseBtn);
    outputRow->addWidget(m_resetOutputBtn);
    outputRow->addStretch();

    m_update = new QCheckBox("Check for updates automatically");
    m_interval = new QComboBox;
    for (const auto &choice : kIntervals) {
        m_interval->addItem(choice.label, choice.days);
    }

    auto *intervalRow = new QHBoxLayout;
    intervalRow->addWidget(new QLabel("Every"));
    intervalRow->addWidget(m_interval);
    intervalRow->addStretch();

    auto *resetAllBtn = new QPushButton("Reset to defaults");
    auto *buttons = new QDialogButtonBox(QDialogButtonBox::Close);
    buttons->addButton(resetAllBtn, QDialogButtonBox::ResetRole);

    auto *layout = new QVBoxLayout(this);
    layout->setContentsMargins(20, 16, 20, 16);
    layout->setSpacing(6);
    layout->addWidget(m_shortNames);
    layout->addWidget(m_shortNamesHint);
    layout->addSpacing(12);
    layout->addWidget(m_report);
    layout->addWidget(reportHint);
    layout->addSpacing(12);
    layout->addWidget(m_outputDir);
    layout->addLayout(outputRow);
    layout->addSpacing(12);
    layout->addWidget(m_update);
    layout->addLayout(intervalRow);
    layout->addSpacing(16);
    layout->addWidget(buttons);

    load();

    connect(m_shortNames, &QCheckBox::toggled, this, [this](bool on) {
        Prefs::setShortNames(on);
        load();
        emit changed();
    });
    connect(m_report, &QCheckBox::toggled, this, [this](bool on) {
        Prefs::setWriteReport(on);
        emit changed();
    });
    connect(chooseBtn, &QPushButton::clicked, this, &PreferencesDialog::chooseOutputDir);
    connect(m_resetOutputBtn, &QPushButton::clicked, this, [this]() {
        Prefs::setCustomOutputDir({});
        refreshOutputDir();
        emit changed();
    });
    connect(m_update, &QCheckBox::toggled, this, [this](bool on) {
        Prefs::setUpdateEnabled(on);
        m_interval->setEnabled(on);
    });
    connect(m_interval, &QComboBox::currentIndexChanged, this, [this](int) {
        Prefs::setUpdateIntervalDays(m_interval->currentData().toInt());
    });
    connect(resetAllBtn, &QPushButton::clicked, this, [this]() {
        Prefs::resetToDefaults();
        load();
        emit changed();
    });
    connect(buttons, &QDialogButtonBox::rejected, this, &QDialog::close);
}

// Widgets are refreshed with signals blocked: their handlers write settings.
void PreferencesDialog::load() {
    const QSignalBlocker b1(m_shortNames);
    const QSignalBlocker b2(m_report);
    const QSignalBlocker b3(m_update);
    const QSignalBlocker b4(m_interval);

    const bool shortNames = Prefs::shortNames();
    m_shortNames->setChecked(shortNames);
    m_shortNamesHint->setText(shortNames
        ? "Channel name only: KICK.wav, ch01.wav"
        : "Session prefix: MyShow_KICK.wav, MyShow_ch01.wav");

    m_report->setChecked(Prefs::writeReport());

    const bool update = Prefs::updateEnabled();
    m_update->setChecked(update);
    m_interval->setEnabled(update);

    const int index = m_interval->findData(Prefs::updateIntervalDays());
    if (index >= 0) {
        m_interval->setCurrentIndex(index);
    }

    refreshOutputDir();
}

void PreferencesDialog::chooseOutputDir() {
    const QString start = Prefs::customOutputDir().isEmpty()
        ? QStandardPaths::writableLocation(QStandardPaths::DesktopLocation)
        : Prefs::customOutputDir();

    const QString dir = QFileDialog::getExistingDirectory(this, "Output folder", start);
    if (dir.isEmpty()) {
        return;
    }

    Prefs::setCustomOutputDir(dir);
    refreshOutputDir();
    emit changed();
}

void PreferencesDialog::refreshOutputDir() {
    const QString dir = Prefs::customOutputDir();
    m_resetOutputBtn->setVisible(!dir.isEmpty());

    if (dir.isEmpty()) {
        m_outputDir->setText("Default output folder: Desktop/<session name>");
        return;
    }
    m_outputDir->setText("Output folder: " + QDir::toNativeSeparators(dir));
}
