// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
#pragma once
#include <QDialog>
#include <QString>
#include <cstdint>

class QCheckBox;
class QComboBox;
class QLabel;
class QPushButton;

// Persisted user settings. Only place that touches QSettings; the update-check
// keys are also written by the Windows installer (HKLM machine default).
namespace Prefs {

bool    shortNames();
void    setShortNames(bool on);

bool    writeReport();
void    setWriteReport(bool on);

// Exact extraction folder chosen by the user; empty means ~/Desktop/<session>.
QString customOutputDir();
void    setCustomOutputDir(const QString &dir);

// Resolved values (Core defaults applied), for display.
bool    updateEnabled();
void    setUpdateEnabled(bool on);
int     updateIntervalDays();
void    setUpdateIntervalDays(int days);

// Raw values for desgrana_update_due: DESGRANA_UNSET when never set.
int32_t updateEnabledSetting();
int32_t updateIntervalSetting();
qint64  lastUpdateCheck();
void    setLastUpdateCheck(qint64 epoch);

void    resetToDefaults();

} // namespace Prefs

class PreferencesDialog : public QDialog {
    Q_OBJECT
public:
    explicit PreferencesDialog(QWidget *parent = nullptr);

signals:
    void changed();

private:
    void load();
    void chooseOutputDir();
    void refreshOutputDir();

    QCheckBox   *m_shortNames;
    QLabel      *m_shortNamesHint;
    QCheckBox   *m_report;
    QLabel      *m_outputDir;
    QPushButton *m_resetOutputBtn;
    QCheckBox   *m_update;
    QComboBox   *m_interval;
};
