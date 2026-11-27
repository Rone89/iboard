//! 单手拇指滑行落点偏移的轻量级在线自适应校准。
//!
//! 记录用户确认上屏词对应的真实触点残差（单位：归一化键宽/键高），通过带收缩与硬上限保护的指数滑动平均（EWMA）
//! 温和修正各字母键的虚拟解码中心，既能适应单手握持时的系统性偏右/偏下漂移，又避免偶发切弯或单次误滑污染键位。

use std::path::Path;

use serde::{Deserialize, Serialize};

use super::GlideKeyboard;

/// 至少累积确认多少次滑行词后才启用键心偏移，避免前 1–2 次偶发滑偏影响后续解码。
const MIN_TOTAL_OBSERVATIONS: u32 = 2;
/// 单个对齐字母允许参与校准的最大欧氏距离（归一化键宽单位）：更远的点多为刻意切弯，不计入落点偏置。
const MAX_SAMPLE_DISTANCE: f32 = 0.78;
/// 单次观测残差的分量裁剪上限（键宽/键高单位）。
const MAX_RESIDUAL: f32 = 0.55;
/// 最终施加到键心的有效偏移硬上限（键宽/键高单位），保证任何情况下不会把键位拖到邻键。
const MAX_EFFECTIVE_OFFSET: f32 = 0.35;
/// 单键与全局偏移的 EWMA 学习率。
const KEY_ALPHA: f32 = 0.16;
const GLOBAL_ALPHA: f32 = 0.09;
/// 每隔多少次有效确认自动落盘一次，避免每次上屏都触发文件写入。
const SAVE_BATCH_SIZE: u16 = 4;

/// 26 键拇指落点偏移状态（按归一化键宽/键高存储，横竖屏与不同键盘高度自动兼容）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GlideKeyCalibrator {
    #[serde(default = "default_offsets")]
    key_offsets: [(f32, f32); 26],
    #[serde(default = "default_counts")]
    key_counts: [u16; 26],
    #[serde(default)]
    global_offset: (f32, f32),
    #[serde(default)]
    total_observations: u32,
    #[serde(skip)]
    dirty_updates: u16,
}

fn default_offsets() -> [(f32, f32); 26] {
    [(0.0, 0.0); 26]
}

fn default_counts() -> [u16; 26] {
    [0; 26]
}

impl Default for GlideKeyCalibrator {
    fn default() -> Self {
        Self {
            key_offsets: default_offsets(),
            key_counts: default_counts(),
            global_offset: (0.0, 0.0),
            total_observations: 0,
            dirty_updates: 0,
        }
    }
}

impl GlideKeyCalibrator {
    /// 已确认的有效滑行校准样本总数。
    #[cfg(test)]
    pub fn total_observations(&self) -> u32 {
        self.total_observations
    }

    /// 是否有尚未落盘的新校准更新。
    pub fn is_dirty(&self) -> bool {
        self.dirty_updates > 0
    }

    /// 达到批量落盘阈值时返回 `true`。
    pub fn should_flush(&self) -> bool {
        self.dirty_updates >= SAVE_BATCH_SIZE
    }

    /// 计算第 `letter_idx` 个字母键此刻应施加的有效偏移（归一化键宽/键高单位）。
    pub fn effective_offset(&self, letter_idx: usize) -> (f32, f32) {
        if self.total_observations < MIN_TOTAL_OBSERVATIONS || letter_idx >= 26 {
            return (0.0, 0.0);
        }
        let key_blend = (f32::from(self.key_counts[letter_idx]) / 5.0).min(1.0);
        let global_blend = ((self.total_observations as f32) / 8.0).min(1.0) * 0.45;
        let (gx, gy) = self.global_offset;
        let (kx, ky) = self.key_offsets[letter_idx];
        let ox = (gx * global_blend + kx * (0.65 * key_blend))
            .clamp(-MAX_EFFECTIVE_OFFSET, MAX_EFFECTIVE_OFFSET);
        let oy = (gy * global_blend + ky * (0.65 * key_blend))
            .clamp(-MAX_EFFECTIVE_OFFSET, MAX_EFFECTIVE_OFFSET);
        if ox.is_finite() && oy.is_finite() {
            (ox, oy)
        } else {
            (0.0, 0.0)
        }
    }

    /// 返回叠加了学习偏移后的虚拟键盘坐标，供 `GlideMatcher` 解码使用。
    pub fn apply(&self, keyboard: &GlideKeyboard) -> GlideKeyboard {
        if self.total_observations < MIN_TOTAL_OBSERVATIONS || !keyboard.is_valid() {
            return keyboard.clone();
        }
        let mut calibrated = keyboard.clone();
        for (idx, center) in calibrated.centers.iter_mut().enumerate() {
            let (ox, oy) = self.effective_offset(idx);
            center.0 += ox * keyboard.key_width;
            center.1 += oy * keyboard.key_height;
        }
        calibrated
    }

    /// 用一次已确认上屏词的对齐结果更新偏移模型。
    ///
    /// `aligned` 为 `(字母下标, 归一化采样 x, 归一化采样 y)`，`raw_centers` 为未偏移时的归一化键心。
    /// 返回 `true` 表示本次确认产生了有效更新。
    pub fn observe_alignment(
        &mut self,
        aligned: &[(usize, f32, f32)],
        raw_centers: &[(f32, f32); 26],
    ) -> bool {
        let mut valid_dx = 0.0f32;
        let mut valid_dy = 0.0f32;
        let mut valid_count = 0usize;
        let mut per_stroke: [(usize, f32, f32); 32] = [(0, 0.0, 0.0); 32];
        for &(idx, sx, sy) in aligned {
            if idx >= 26 || !sx.is_finite() || !sy.is_finite() {
                continue;
            }
            let (cx, cy) = raw_centers[idx];
            let dx = sx - cx;
            let dy = sy - cy;
            if (dx * dx + dy * dy).sqrt() > MAX_SAMPLE_DISTANCE {
                continue;
            }
            let cdx = dx.clamp(-MAX_RESIDUAL, MAX_RESIDUAL);
            let cdy = dy.clamp(-MAX_RESIDUAL, MAX_RESIDUAL);
            if valid_count < per_stroke.len() {
                per_stroke[valid_count] = (idx, cdx, cdy);
            }
            valid_dx += cdx;
            valid_dy += cdy;
            valid_count += 1;
        }
        if valid_count < 2 {
            return false;
        }
        let stroke_mean_x = valid_dx / valid_count as f32;
        let stroke_mean_y = valid_dy / valid_count as f32;
        if self.total_observations == 0 {
            self.global_offset = (stroke_mean_x * 0.5, stroke_mean_y * 0.5);
        } else {
            self.global_offset.0 =
                self.global_offset.0 * (1.0 - GLOBAL_ALPHA) + stroke_mean_x * GLOBAL_ALPHA;
            self.global_offset.1 =
                self.global_offset.1 * (1.0 - GLOBAL_ALPHA) + stroke_mean_y * GLOBAL_ALPHA;
        }
        for &(idx, cdx, cdy) in &per_stroke[..valid_count.min(per_stroke.len())] {
            let count = self.key_counts[idx];
            if count == 0 {
                self.key_offsets[idx] = (cdx * 0.5, cdy * 0.5);
            } else {
                self.key_offsets[idx].0 =
                    self.key_offsets[idx].0 * (1.0 - KEY_ALPHA) + cdx * KEY_ALPHA;
                self.key_offsets[idx].1 =
                    self.key_offsets[idx].1 * (1.0 - KEY_ALPHA) + cdy * KEY_ALPHA;
            }
            self.key_counts[idx] = count.saturating_add(1);
        }
        self.total_observations = self.total_observations.saturating_add(1);
        self.dirty_updates = self.dirty_updates.saturating_add(1);
        true
    }

    /// 从用户数据目录读取持久化的校准文件；缺失、非法或符号链接时静默回退默认空态。
    pub fn load(path: &Path) -> Self {
        if path.as_os_str().is_empty() {
            return Self::default();
        }
        let Ok(meta) = std::fs::symlink_metadata(path) else {
            return Self::default();
        };
        if !meta.file_type().is_file() || meta.len() > 16 * 1024 {
            return Self::default();
        }
        let Ok(bytes) = std::fs::read(path) else {
            return Self::default();
        };
        let mut loaded: Self = serde_json::from_slice(&bytes).unwrap_or_default();
        loaded.sanitize();
        loaded
    }

    /// 将当前校准状态落盘到 `path`；写失败时静默忽略，不阻塞输入。
    pub fn save(&mut self, path: &Path) {
        if path.as_os_str().is_empty() || self.dirty_updates == 0 {
            return;
        }
        let Some(parent) = path.parent() else {
            return;
        };
        if std::fs::create_dir_all(parent).is_err() {
            return;
        }
        let Ok(encoded) = serde_json::to_vec(self) else {
            return;
        };
        let tmp = path.with_extension("json.tmp");
        if std::fs::write(&tmp, encoded).is_ok() && std::fs::rename(&tmp, path).is_ok() {
            self.dirty_updates = 0;
        } else {
            let _ = std::fs::remove_file(&tmp);
        }
    }

    fn sanitize(&mut self) {
        if !self.global_offset.0.is_finite() || !self.global_offset.1.is_finite() {
            self.global_offset = (0.0, 0.0);
        } else {
            self.global_offset.0 = self.global_offset.0.clamp(-MAX_RESIDUAL, MAX_RESIDUAL);
            self.global_offset.1 = self.global_offset.1.clamp(-MAX_RESIDUAL, MAX_RESIDUAL);
        }
        for offset in &mut self.key_offsets {
            if !offset.0.is_finite() || !offset.1.is_finite() {
                *offset = (0.0, 0.0);
            } else {
                offset.0 = offset.0.clamp(-MAX_RESIDUAL, MAX_RESIDUAL);
                offset.1 = offset.1.clamp(-MAX_RESIDUAL, MAX_RESIDUAL);
            }
        }
        self.dirty_updates = 0;
    }
}
