package com.pornshop.player.ui

import android.content.Context
import com.pornshop.player.BuildConfig

object AppRelease {
    val versionName: String = BuildConfig.VERSION_NAME.removeSuffix("-debug")

    val notes: List<String> = listOf(
        "新增懂色帝公开页面播放源",
        "新增 AVJB、91rb 官网访问入口",
        "接入好色 TV",
        "学习页日期和「最近学习」跟随当前时间",
        "修复已知显示BUG",
    )

    fun shouldPrompt(context: Context): Boolean {
        val seen = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_SEEN, null)
        return seen != versionName
    }

    fun markPrompted(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_SEEN, versionName)
            .apply()
    }

    private const val PREFS = "pornshop_release"
    private const val KEY_SEEN = "notes_seen_version"
}
