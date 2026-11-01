package com.pornshop.player.ui

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

object AppleGlassColors {
    // Core Apple Music / iOS Vision Glass Accents
    val AccentPink = Color(0xFFFF2D55)
    val AccentCoral = Color(0xFFFF6482)
    val AccentBlue = Color(0xFF007AFF)
    val AccentIndigo = Color(0xFF5856D6)
    val AccentEmerald = Color(0xFF10B981)
    val AccentAmber = Color(0xFFF59E0B)

    // Light Pearl & Frosted Glass Surfaces
    val BgBase = Color(0xFFF3F5FA)
    val BgTopTint = Color(0xFFF9FAFE)
    val BgRoseOrb = Color(0xFFFFDFE8)
    val BgSkyOrb = Color(0xFFDCEBFF)
    val BgLavenderOrb = Color(0xFFEBE4FF)

    val GlassWhite = Color(0xFFFFFFFF).copy(alpha = 0.76f)
    val GlassWhiteStrong = Color(0xFFFFFFFF).copy(alpha = 0.90f)
    val GlassWhiteSubtle = Color(0xFFFFFFFF).copy(alpha = 0.58f)
    val GlassBorderHighlight = Color(0xFFFFFFFF).copy(alpha = 0.95f)
    val GlassBorderOuter = Color(0xFF0F172A).copy(alpha = 0.06f)

    // Dark Frosted Glass for Video Player HUD
    val HudGlassDark = Color(0xFF141824).copy(alpha = 0.64f)
    val HudGlassPill = Color(0xFF1E2434).copy(alpha = 0.74f)
    val HudGlassBorder = Color(0xFFFFFFFF).copy(alpha = 0.22f)

    // Typography
    val TextPrimary = Color(0xFF0F172A)
    val TextSecondary = Color(0xFF475569)
    val TextTertiary = Color(0xFF94A3B8)

    val AccentGradient = Brush.linearGradient(
        colors = listOf(AccentPink, AccentCoral),
    )

    val VipGoldGradient = Brush.linearGradient(
        colors = listOf(Color(0xFFFF2D55), Color(0xFFFF7A59)),
    )
}

/**
 * Apple VisionOS / iOS 18 Light Glass ambient background with soft pearlescent light orbs.
 */
@Composable
fun AppleGlassBackground(
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    Box(
        modifier = modifier
            .fillMaxSize()
            .background(AppleGlassColors.BgBase)
            .drawBehind {
                val w = size.width
                val h = size.height
                drawRect(
                    brush = Brush.verticalGradient(
                        colors = listOf(
                            AppleGlassColors.BgTopTint,
                            AppleGlassColors.BgBase,
                            Color(0xFFEEF2F8),
                        ),
                    ),
                )
                drawCircle(
                    brush = Brush.radialGradient(
                        colors = listOf(
                            AppleGlassColors.BgRoseOrb.copy(alpha = 0.65f),
                            Color.Transparent,
                        ),
                        center = Offset(w * 0.88f, h * 0.08f),
                        radius = w * 0.72f,
                    ),
                    center = Offset(w * 0.88f, h * 0.08f),
                    radius = w * 0.72f,
                )
                drawCircle(
                    brush = Brush.radialGradient(
                        colors = listOf(
                            AppleGlassColors.BgSkyOrb.copy(alpha = 0.65f),
                            Color.Transparent,
                        ),
                        center = Offset(w * 0.12f, h * 0.28f),
                        radius = w * 0.78f,
                    ),
                    center = Offset(w * 0.12f, h * 0.28f),
                    radius = w * 0.78f,
                )
                drawCircle(
                    brush = Brush.radialGradient(
                        colors = listOf(
                            AppleGlassColors.BgLavenderOrb.copy(alpha = 0.48f),
                            Color.Transparent,
                        ),
                        center = Offset(w * 0.75f, h * 0.75f),
                        radius = w * 0.80f,
                    ),
                    center = Offset(w * 0.75f, h * 0.75f),
                    radius = w * 0.80f,
                )
            },
    ) {
        content()
    }
}

/**
 * Frosted light glass card modifier with soft ambient shadow + dual specular highlight border.
 */
fun Modifier.appleGlassCard(
    shape: Shape = RoundedCornerShape(20.dp),
    surfaceColor: Color = AppleGlassColors.GlassWhite,
    elevation: Dp = 8.dp,
): Modifier = this
    .shadow(
        elevation = elevation,
        shape = shape,
        ambientColor = Color(0xFF0F172A).copy(alpha = 0.08f),
        spotColor = Color(0xFF0F172A).copy(alpha = 0.08f),
    )
    .clip(shape)
    .background(
        brush = Brush.verticalGradient(
            colors = listOf(
                surfaceColor.copy(alpha = (surfaceColor.alpha + 0.08f).coerceAtMost(0.96f)),
                surfaceColor,
            ),
        ),
        shape = shape,
    )
    .border(
        width = 1.dp,
        brush = Brush.verticalGradient(
            colors = listOf(
                AppleGlassColors.GlassBorderHighlight,
                AppleGlassColors.GlassBorderOuter,
            ),
        ),
        shape = shape,
    )

/**
 * Dark frosted glass pill modifier for video HUD overlays.
 */
fun Modifier.hudGlassSurface(
    shape: Shape = RoundedCornerShape(999.dp),
    backgroundColor: Color = AppleGlassColors.HudGlassDark,
): Modifier = this
    .clip(shape)
    .background(backgroundColor, shape)
    .border(
        width = 0.8.dp,
        brush = Brush.verticalGradient(
            colors = listOf(
                Color.White.copy(alpha = 0.26f),
                Color.White.copy(alpha = 0.08f),
            ),
        ),
        shape = shape,
    )

/**
 * Apple iOS-style segmented control with frosted glass track and floating white active pill.
 */
@Composable
fun AppleSegmentedControl(
    items: List<Pair<String, ImageVector?>>,
    selectedIndex: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(Color(0xFFE2E8F0).copy(alpha = 0.65f))
            .border(
                width = 1.dp,
                color = Color.White.copy(alpha = 0.85f),
                shape = RoundedCornerShape(16.dp),
            )
            .padding(4.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        items.forEachIndexed { idx, (label, icon) ->
            val selected = idx == selectedIndex
            val bgColor by animateColorAsState(
                targetValue = if (selected) Color.White.copy(alpha = 0.95f) else Color.Transparent,
                animationSpec = tween(220, easing = FastOutSlowInEasing),
                label = "segBg",
            )
            val textColor by animateColorAsState(
                targetValue = if (selected) AppleGlassColors.AccentPink else AppleGlassColors.TextSecondary,
                animationSpec = tween(220),
                label = "segText",
            )
            Box(
                modifier = Modifier
                    .weight(1f)
                    .then(
                        if (selected) {
                            Modifier.shadow(
                                elevation = 4.dp,
                                shape = RoundedCornerShape(12.dp),
                                ambientColor = Color.Black.copy(alpha = 0.08f),
                                spotColor = Color.Black.copy(alpha = 0.08f),
                            )
                        } else {
                            Modifier
                        },
                    )
                    .clip(RoundedCornerShape(12.dp))
                    .background(bgColor)
                    .clickable { onSelect(idx) }
                    .padding(vertical = 8.dp, horizontal = 6.dp),
                contentAlignment = Alignment.Center,
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.Center,
                ) {
                    if (icon != null) {
                        Icon(
                            imageVector = icon,
                            contentDescription = null,
                            tint = textColor,
                            modifier = Modifier.size(15.dp),
                        )
                        Spacer(modifier = Modifier.width(4.dp))
                    }
                    Text(
                        text = label,
                        color = textColor,
                        fontSize = 13.sp,
                        fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium,
                        maxLines = 1,
                    )
                }
            }
        }
    }
}

/**
 * Apple Light Glass Filter Chip Pill.
 */
@Composable
fun AppleGlassChip(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    leadingIcon: ImageVector? = null,
) {
    val shape = RoundedCornerShape(999.dp)
    Box(
        modifier = modifier
            .then(
                if (selected) {
                    Modifier
                        .shadow(
                            elevation = 5.dp,
                            shape = shape,
                            ambientColor = AppleGlassColors.AccentPink.copy(alpha = 0.35f),
                            spotColor = AppleGlassColors.AccentPink.copy(alpha = 0.35f),
                        )
                        .clip(shape)
                        .background(AppleGlassColors.AccentGradient, shape)
                } else {
                    Modifier
                        .clip(shape)
                        .background(Color.White.copy(alpha = 0.72f), shape)
                        .border(
                            width = 1.dp,
                            color = Color.White.copy(alpha = 0.92f),
                            shape = shape,
                        )
                },
            )
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 7.dp),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center,
        ) {
            if (leadingIcon != null) {
                Icon(
                    imageVector = leadingIcon,
                    contentDescription = null,
                    tint = if (selected) Color.White else AppleGlassColors.TextSecondary,
                    modifier = Modifier.size(14.dp),
                )
                Spacer(modifier = Modifier.width(4.dp))
            }
            Text(
                text = label,
                color = if (selected) Color.White else AppleGlassColors.TextPrimary,
                style = MaterialTheme.typography.labelMedium.copy(
                    fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium,
                    fontSize = 13.sp,
                ),
            )
        }
    }
}

/**
 * Animated shimmer brush for skeleton loading cards.
 */
fun Modifier.shimmerEffect(): Modifier = composed {
    val transition = rememberInfiniteTransition(label = "shimmer")
    val translateAnim by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1200f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1200, easing = FastOutSlowInEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "shimmerAnim",
    )
    background(
        brush = Brush.linearGradient(
            colors = listOf(
                Color(0xFFE2E8F0).copy(alpha = 0.55f),
                Color(0xFFF8FAFC).copy(alpha = 0.90f),
                Color(0xFFE2E8F0).copy(alpha = 0.55f),
            ),
            start = Offset(translateAnim - 400f, translateAnim - 400f),
            end = Offset(translateAnim, translateAnim),
        ),
    )
}

@Composable
fun YouTubeCardShimmer(isGrid: Boolean = false) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .appleGlassCard(shape = RoundedCornerShape(20.dp), elevation = 4.dp)
            .padding(if (isGrid) 8.dp else 12.dp),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(16f / 9f)
                .clip(RoundedCornerShape(14.dp))
                .shimmerEffect(),
        )
        Spacer(modifier = Modifier.height(10.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (!isGrid) {
                Box(
                    modifier = Modifier
                        .size(36.dp)
                        .clip(CircleShape)
                        .shimmerEffect(),
                )
                Spacer(modifier = Modifier.width(10.dp))
            }
            Column(modifier = Modifier.weight(1f)) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth(0.85f)
                        .height(14.dp)
                        .clip(RoundedCornerShape(6.dp))
                        .shimmerEffect(),
                )
                Spacer(modifier = Modifier.height(6.dp))
                Box(
                    modifier = Modifier
                        .fillMaxWidth(0.55f)
                        .height(11.dp)
                        .clip(RoundedCornerShape(6.dp))
                        .shimmerEffect(),
                )
            }
        }
    }
}
