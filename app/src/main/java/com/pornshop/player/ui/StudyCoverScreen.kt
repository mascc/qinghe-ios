package com.pornshop.player.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoStories
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Explore
import androidx.compose.material.icons.filled.MenuBook
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import java.time.LocalDateTime

private val Paper = Color(0xFFF6F3EC)
private val Ink = Color(0xFF1C1917)
private val Moss = Color(0xFF1F6B4A)
private val MossSoft = Color(0xFFE5F2EB)
private val Clay = Color(0xFFC4652D)
private val Navy = Color(0xFF243E66)
private val Line = Color(0xFFE4DDD2)
private val Muted = Color(0xFF78716C)

private data class Course(
    val id: String,
    val subject: String,
    val title: String,
    val teacher: String,
    val progress: Float,
    val lesson: String,
    val minutes: Int,
    val accent: Color,
    val chapters: List<String>,
)

private val courses = listOf(
    Course(
        id = "en",
        subject = "英语听力",
        title = "校园对话精听",
        teacher = "周宁",
        progress = 0.62f,
        lesson = "第 12 讲 · 图书馆借阅",
        minutes = 25,
        accent = Moss,
        chapters = listOf(
            "听前：圈出时间、地点、数字",
            "第一遍只抓谁在说话",
            "第二遍写下图书馆的开放时间",
            "对照原文，标出连读",
        ),
    ),
    Course(
        id = "math",
        subject = "高等数学",
        title = "极限与连续",
        teacher = "陈疏影",
        progress = 0.41f,
        lesson = "第 7 讲 · ε-δ 定义",
        minutes = 40,
        accent = Navy,
        chapters = listOf(
            "用日常语言重述极限",
            "ε 是误差，δ 是允许的靠近程度",
            "完成课本例题 2 和例题 3",
            "自己写一句「当 x 靠近 a」",
        ),
    ),
    Course(
        id = "net",
        subject = "计算机网络",
        title = "应用层概览",
        teacher = "许衡",
        progress = 0.23f,
        lesson = "第 4 讲 · 请求与响应",
        minutes = 30,
        accent = Clay,
        chapters = listOf(
            "区分网址、主机和路径",
            "看一则请求里的方法与状态码",
            "记住常见的 200、301、404",
            "用自己的话解释「无状态」",
        ),
    ),
)

private enum class CoverTab(val label: String, val icon: ImageVector) {
    Study("学习", Icons.Default.MenuBook),
    Courses("课程", Icons.Default.AutoStories),
    Discover("发现", Icons.Default.Explore),
    Me("我的", Icons.Default.Person),
}

private val courseCode = "886"
private val weekNames = arrayOf("周一", "周二", "周三", "周四", "周五", "周六", "周日")

@Composable
private fun rememberClock(): LocalDateTime {
    var now by remember { mutableStateOf(LocalDateTime.now()) }
    LaunchedEffect(Unit) {
        while (true) {
            now = LocalDateTime.now()
            delay(1_000)
        }
    }
    return now
}

private fun studyDateLine(now: LocalDateTime): String {
    val week = weekNames[now.dayOfWeek.value - 1]
    val hh = now.hour.toString().padStart(2, '0')
    val mm = now.minute.toString().padStart(2, '0')
    return "${now.monthValue}月${now.dayOfMonth}日 · $week · $hh:$mm"
}

@Composable
fun StudyCoverScreen(onUnlock: () -> Unit) {
    val scheme = lightColorScheme(
        primary = Moss,
        onPrimary = Color.White,
        primaryContainer = MossSoft,
        onPrimaryContainer = Moss,
        background = Paper,
        onBackground = Ink,
        surface = Color.White,
        onSurface = Ink,
        surfaceVariant = Color(0xFFF3EEE6),
        onSurfaceVariant = Muted,
        outline = Line,
    )
    MaterialTheme(colorScheme = scheme) {
        var tab by remember { mutableStateOf(CoverTab.Study) }
        var openCourseId by remember { mutableStateOf<String?>(null) }
        var focusJoin by remember { mutableStateOf(false) }
        val openCourse = courses.firstOrNull { it.id == openCourseId }

        if (openCourse != null) {
            BackHandler { openCourseId = null }
            LessonPage(course = openCourse, onBack = { openCourseId = null })
            return@MaterialTheme
        }

        Column(
            modifier = Modifier
                .fillMaxSize()
                .background(Paper)
                .navigationBarsPadding(),
        ) {
            Column(
                modifier = Modifier
                    .weight(1f)
                    .verticalScroll(rememberScrollState())
                    .statusBarsPadding()
                    .padding(horizontal = 20.dp),
            ) {
                Spacer(modifier = Modifier.height(12.dp))
                when (tab) {
                    CoverTab.Study -> StudyPage(
                        onOpenCourse = { openCourseId = it },
                        onJoin = {
                            tab = CoverTab.Courses
                            focusJoin = true
                        },
                    )
                    CoverTab.Courses -> CoursesPage(
                        focusJoin = focusJoin,
                        onFocusConsumed = { focusJoin = false },
                        onOpenCourse = { openCourseId = it },
                        onUnlock = onUnlock,
                    )
                    CoverTab.Discover -> DiscoverPage()
                    CoverTab.Me -> ProfilePage()
                }
                Spacer(modifier = Modifier.height(18.dp))
            }
            CoverBottomBar(selected = tab, onSelect = { tab = it })
        }
    }
}

@Composable
private fun StudyPage(onOpenCourse: (String) -> Unit, onJoin: () -> Unit) {
    val today = courses.first()
    val now = rememberClock()
    Text(
        text = "青禾学堂",
        color = Ink,
        fontSize = 28.sp,
        fontWeight = FontWeight.SemiBold,
        fontFamily = FontFamily.Serif,
    )
    Text(
        text = studyDateLine(now),
        color = Muted,
        fontSize = 13.sp,
        modifier = Modifier.padding(top = 2.dp, bottom = 18.dp),
    )
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .background(Moss)
            .clickable { onOpenCourse(today.id) }
            .padding(18.dp),
    ) {
        Text(text = "今日安排", color = Color.White.copy(alpha = 0.75f), fontSize = 12.sp)
        Text(
            text = today.lesson,
            color = Color.White,
            fontSize = 20.sp,
            fontWeight = FontWeight.SemiBold,
            fontFamily = FontFamily.Serif,
            modifier = Modifier.padding(top = 6.dp),
        )
        Text(
            text = "${today.subject} · ${today.teacher} · ${today.minutes} 分钟",
            color = Color.White.copy(alpha = 0.86f),
            fontSize = 13.sp,
            modifier = Modifier.padding(top = 6.dp, bottom = 14.dp),
        )
        LinearProgressIndicator(
            progress = { today.progress },
            modifier = Modifier
                .fillMaxWidth()
                .height(4.dp)
                .clip(RoundedCornerShape(2.dp)),
            color = Color(0xFFE7C56A),
            trackColor = Color.White.copy(alpha = 0.25f),
        )
        Text(
            text = "已完成 ${(today.progress * 100).toInt()}%  ·  继续这一讲",
            color = Color.White,
            fontSize = 13.sp,
            modifier = Modifier.padding(top = 10.dp),
        )
    }

    Spacer(modifier = Modifier.height(18.dp))
    Text(text = "本周", color = Ink, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
    Spacer(modifier = Modifier.height(10.dp))
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        StatChip("5", "学习天数", Modifier.weight(1f))
        StatChip("11", "完成课时", Modifier.weight(1f))
        StatChip("6", "笔记", Modifier.weight(1f))
        StatChip("2", "待复习", Modifier.weight(1f))
    }

    Spacer(modifier = Modifier.height(18.dp))
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(text = "继续学习", color = Ink, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
        Text(
            text = "加入课程",
            color = Moss,
            fontSize = 13.sp,
            fontWeight = FontWeight.Medium,
            modifier = Modifier.clickable(onClick = onJoin),
        )
    }
    Spacer(modifier = Modifier.height(10.dp))
    courses.forEach { course ->
        CourseRow(course = course, onClick = { onOpenCourse(course.id) })
        Spacer(modifier = Modifier.height(8.dp))
    }
}

@Composable
private fun CoursesPage(
    focusJoin: Boolean,
    onFocusConsumed: () -> Unit,
    onOpenCourse: (String) -> Unit,
    onUnlock: () -> Unit,
) {
    Text(
        text = "我的课程",
        color = Ink,
        fontSize = 28.sp,
        fontWeight = FontWeight.SemiBold,
        fontFamily = FontFamily.Serif,
    )
    Text(
        text = "三门进行中",
        color = Muted,
        fontSize = 13.sp,
        modifier = Modifier.padding(top = 2.dp, bottom = 14.dp),
    )
    courses.forEach { course ->
        CourseRow(course = course, onClick = { onOpenCourse(course.id) })
        Spacer(modifier = Modifier.height(8.dp))
    }
    Spacer(modifier = Modifier.height(8.dp))
    JoinCourseCard(
        focusNow = focusJoin,
        onFocusConsumed = onFocusConsumed,
        onUnlock = onUnlock,
    )
}

@Composable
private fun JoinCourseCard(
    focusNow: Boolean,
    onFocusConsumed: () -> Unit,
    onUnlock: () -> Unit,
) {
    var code by remember { mutableStateOf("") }
    var message by remember { mutableStateOf<String?>(null) }
    var opening by remember { mutableStateOf(false) }
    val focusRequester = remember { FocusRequester() }

    LaunchedEffect(focusNow) {
        if (focusNow) {
            delay(60)
            focusRequester.requestFocus()
            onFocusConsumed()
        }
    }
    LaunchedEffect(opening) {
        if (opening) {
            delay(280)
            onUnlock()
        }
    }

    fun submit() {
        if (opening) return
        val entered = code.trim()
        when {
            entered.isEmpty() -> message = "请输入课程码"
            entered == courseCode -> {
                message = null
                opening = true
            }
            else -> message = "没有找到这个课程，请核对课程码"
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .background(Color.White)
            .border(1.dp, Line, RoundedCornerShape(18.dp))
            .padding(16.dp),
    ) {
        Text(text = "加入新课程", color = Ink, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
        Text(
            text = "向老师索取课程码，加入后即可学习完整课时。",
            color = Muted,
            fontSize = 13.sp,
            modifier = Modifier.padding(top = 4.dp, bottom = 12.dp),
        )
        OutlinedTextField(
            value = code,
            onValueChange = {
                code = it.filter { ch -> ch.isDigit() }.take(8)
                message = null
            },
            modifier = Modifier
                .fillMaxWidth()
                .focusRequester(focusRequester),
            enabled = !opening,
            singleLine = true,
            label = { Text("课程码") },
            keyboardOptions = KeyboardOptions(
                keyboardType = KeyboardType.Number,
                imeAction = ImeAction.Done,
            ),
            keyboardActions = KeyboardActions(onDone = { submit() }),
        )
        if (message != null) {
            Text(
                text = message!!,
                color = Clay,
                fontSize = 13.sp,
                modifier = Modifier.padding(top = 8.dp),
            )
        }
        Button(
            onClick = { submit() },
            enabled = !opening,
            modifier = Modifier
                .padding(top = 12.dp)
                .fillMaxWidth()
                .height(48.dp),
            shape = RoundedCornerShape(12.dp),
        ) {
            Text(if (opening) "正在打开课堂…" else "加入")
        }
    }
}

@Composable
private fun DiscoverPage() {
    Text(
        text = "发现",
        color = Ink,
        fontSize = 28.sp,
        fontWeight = FontWeight.SemiBold,
        fontFamily = FontFamily.Serif,
    )
    Text(
        text = "短文，读完即可",
        color = Muted,
        fontSize = 13.sp,
        modifier = Modifier.padding(top = 2.dp, bottom = 14.dp),
    )
    ArticleCard(
        kicker = "方法",
        title = "一次只听一分钟",
        body = "听力卡住时，把音频停在一个句子上。先跟读，再默写。默写对了再往下走，比一遍遍从头放到尾更记得住。",
    )
    Spacer(modifier = Modifier.height(10.dp))
    ArticleCard(
        kicker = "笔记",
        title = "公式旁边写一句人话",
        body = "极限、导数、积分都先用自己的话说一遍，再抄符号。隔天复习时，人话比符号更容易把步骤唤回来。",
    )
    Spacer(modifier = Modifier.height(10.dp))
    ArticleCard(
        kicker = "复习",
        title = "错题隔两天再看",
        body = "刚做对的题明天会忘。把错题日期记在页边，两天后再独立做一遍。第二次做对，才算这一小段稳住了。",
    )
}

@Composable
private fun ProfilePage() {
    val now = rememberClock()
    val hh = now.hour.toString().padStart(2, '0')
    val mm = now.minute.toString().padStart(2, '0')
    Text(
        text = "我的",
        color = Ink,
        fontSize = 28.sp,
        fontWeight = FontWeight.SemiBold,
        fontFamily = FontFamily.Serif,
    )
    Spacer(modifier = Modifier.height(16.dp))
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
            modifier = Modifier
                .size(58.dp)
                .clip(CircleShape)
                .background(MossSoft),
            contentAlignment = Alignment.Center,
        ) {
            Text(text = "林", color = Moss, fontSize = 22.sp, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Serif)
        }
        Spacer(modifier = Modifier.width(14.dp))
        Column {
            Text(text = "林知夏", color = Ink, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
            Text(text = "青禾公开课 · 202418086", color = Muted, fontSize = 13.sp)
        }
    }
    Spacer(modifier = Modifier.height(18.dp))
    ProfileLine("本周学习", "4 小时 20 分")
    ProfileLine("连续打卡", "5 天")
    ProfileLine("进行中的课", "3 门")
    ProfileLine("最近学习", "今天 $hh:$mm")
    Spacer(modifier = Modifier.height(14.dp))
    Text(
        text = "课时记录保存在这台设备上。",
        color = Muted,
        fontSize = 12.sp,
    )
}

@Composable
private fun LessonPage(course: Course, onBack: () -> Unit) {
    var done by remember(course.id) { mutableStateOf(false) }
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Paper)
            .statusBarsPadding()
            .navigationBarsPadding()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp),
    ) {
        Text(
            text = "返回",
            color = Moss,
            fontSize = 15.sp,
            modifier = Modifier
                .padding(top = 12.dp)
                .clickable(onClick = onBack),
        )
        Text(
            text = course.subject,
            color = Muted,
            fontSize = 13.sp,
            modifier = Modifier.padding(top = 16.dp),
        )
        Text(
            text = course.lesson,
            color = Ink,
            fontSize = 26.sp,
            fontWeight = FontWeight.SemiBold,
            fontFamily = FontFamily.Serif,
            modifier = Modifier.padding(top = 4.dp),
        )
        Text(
            text = "${course.teacher}  ·  ${course.minutes} 分钟",
            color = Muted,
            fontSize = 13.sp,
            modifier = Modifier.padding(top = 6.dp, bottom = 16.dp),
        )
        course.chapters.forEachIndexed { index, line ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(bottom = 8.dp)
                    .clip(RoundedCornerShape(14.dp))
                    .background(Color.White)
                    .padding(horizontal = 14.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = "${index + 1}",
                    color = course.accent,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 14.sp,
                    modifier = Modifier.width(22.dp),
                )
                Text(text = line, color = Ink, fontSize = 15.sp)
            }
        }
        Button(
            onClick = { done = !done },
            modifier = Modifier
                .padding(top = 8.dp, bottom = 24.dp)
                .fillMaxWidth()
                .height(48.dp),
            shape = RoundedCornerShape(12.dp),
        ) {
            if (done) {
                Icon(Icons.Default.Check, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(modifier = Modifier.width(6.dp))
            }
            Text(if (done) "这一讲已标记学完" else "标记本讲已学")
        }
    }
}

@Composable
private fun CourseRow(course: Course, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(Color.White)
            .clickable(onClick = onClick)
            .padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .width(4.dp)
                .height(42.dp)
                .clip(RoundedCornerShape(2.dp))
                .background(course.accent),
        )
        Spacer(modifier = Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(text = course.subject, color = Muted, fontSize = 12.sp)
            Text(text = course.title, color = Ink, fontSize = 16.sp, fontWeight = FontWeight.Medium)
            Text(
                text = course.lesson,
                color = Muted,
                fontSize = 12.sp,
                modifier = Modifier.padding(top = 2.dp),
            )
        }
        Icon(
            imageVector = Icons.Outlined.ChevronRight,
            contentDescription = null,
            tint = Muted,
        )
    }
}

@Composable
private fun StatChip(value: String, label: String, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(14.dp))
            .background(Color.White)
            .padding(vertical = 10.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(text = value, color = Ink, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
        Text(text = label, color = Muted, fontSize = 11.sp)
    }
}

@Composable
private fun ArticleCard(kicker: String, title: String, body: String) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(Color.White)
            .padding(16.dp),
    ) {
        Text(text = kicker, color = Moss, fontSize = 12.sp, fontWeight = FontWeight.Medium)
        Text(
            text = title,
            color = Ink,
            fontSize = 17.sp,
            fontWeight = FontWeight.SemiBold,
            fontFamily = FontFamily.Serif,
            modifier = Modifier.padding(top = 4.dp, bottom = 6.dp),
        )
        Text(text = body, color = Color(0xFF44403C), fontSize = 14.sp, lineHeight = 21.sp)
    }
}

@Composable
private fun ProfileLine(label: String, value: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 11.dp)
            .border(width = 0.dp, color = Color.Transparent),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(text = label, color = Muted, fontSize = 15.sp)
        Text(text = value, color = Ink, fontSize = 15.sp)
    }
    Box(modifier = Modifier.fillMaxWidth().height(1.dp).background(Line))
}

@Composable
private fun CoverBottomBar(selected: CoverTab, onSelect: (CoverTab) -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(Color.White)
            .padding(top = 6.dp, bottom = 8.dp),
        horizontalArrangement = Arrangement.SpaceEvenly,
    ) {
        CoverTab.entries.forEach { item ->
            val active = item == selected
            Column(
                modifier = Modifier
                    .clip(RoundedCornerShape(12.dp))
                    .clickable { onSelect(item) }
                    .padding(horizontal = 12.dp, vertical = 4.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Icon(
                    imageVector = item.icon,
                    contentDescription = item.label,
                    tint = if (active) Moss else Muted,
                    modifier = Modifier.size(22.dp),
                )
                Text(
                    text = item.label,
                    color = if (active) Moss else Muted,
                    fontSize = 11.sp,
                    fontWeight = if (active) FontWeight.SemiBold else FontWeight.Normal,
                )
            }
        }
    }
}
