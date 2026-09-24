import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_symbols_icons/symbols.dart';

/// Renders the real marketing/brand logo for AI providers and models
/// (e.g. OpenAI, Anthropic Claude, DeepSeek, Kimi, Qwen, OpenCode, Gemini, Mistral, Ollama, Meta, NVIDIA NIM, Z-AI).
class ModelBrandIcon extends StatelessWidget {
  final String providerId;
  final String? displayName;
  final String? modelName;
  final double size;

  const ModelBrandIcon({
    super.key,
    required this.providerId,
    this.displayName,
    this.modelName,
    this.size = 16,
  });

  /// Resolves the canonical brand key from the model name, provider ID, or display name.
  static String resolveBrandKey({
    required String providerId,
    String? displayName,
    String? modelName,
  }) {
    final m = modelName?.toLowerCase() ?? '';
    final d = displayName?.toLowerCase() ?? '';
    final p = providerId.toLowerCase();

    // 1. Model name has highest precedence for individual model tiles
    if (m.isNotEmpty) {
      if (m.contains('deepseek')) return 'deepseek';
      if (m.contains('qwen') || m.contains('alibaba')) return 'qwen';
      if (m.contains('kimi') || m.contains('moonshot')) return 'kimi';
      if (m.contains('claude') || m.contains('anthropic')) return 'claude';
      if (m.contains('gpt') || m.contains('o1') || m.contains('o3') || m.contains('o4') || m.contains('chatgpt') || m.contains('dall-e') || m.contains('openai') || m.contains('open ai')) {
        return 'openai';
      }
      if (m.contains('gemini') || m.contains('gemma')) return 'gemini';
      if (m.contains('mistral') || m.contains('codestral') || m.contains('pixtral')) return 'mistral';
      if (m.contains('llama') || m.contains('meta')) return 'meta';
      if (m.contains('z.ai') || m.contains('z-ai') || m.contains('zai') || m.contains('glm') || m.contains('zhipu') || m.contains('chatglm') || m.contains('bigmodel')) {
        return 'zai';
      }
      if (m.contains('nvidia') || m.contains('nim') || m.contains('nemotron') || m.contains('nvlm')) {
        return 'nvidia';
      }
      if (m.contains('groq')) return 'groq';
      if (m.contains('copilot')) return 'copilot';
      if (m.contains('command-r') || m.contains('cohere')) return 'cohere';
    }

    // 2. Display name and provider ID fallback
    final combined = '$p $d';
    if (combined.contains('kimi') || combined.contains('moonshot')) return 'kimi';
    if (combined.contains('deepseek')) return 'deepseek';
    if (combined.contains('qwen') || combined.contains('alibaba')) return 'qwen';
    if (combined.contains('claude') || combined.contains('anthropic')) return 'claude';
    if (combined.contains('openai') || combined.contains('open ai') || combined.contains('chatgpt')) return 'openai';
    if (combined.contains('nvidia') || combined.contains('nim')) return 'nvidia';
    if (combined.contains('meta') || combined.contains('llama')) return 'meta';
    if (combined.contains('z.ai') || combined.contains('z-ai') || combined.contains('zai') || combined.contains('zhipu') || combined.contains('glm') || combined.contains('bigmodel')) {
      return 'zai';
    }
    if (combined.contains('opencode')) return 'opencode';
    if (combined.contains('gemini') || combined.contains('google')) return 'gemini';
    if (combined.contains('mistral')) return 'mistral';
    if (combined.contains('ollama') || combined.contains('local')) return 'ollama';
    if (combined.contains('groq')) return 'groq';
    if (combined.contains('copilot') || combined.contains('github')) return 'copilot';
    if (combined.contains('openrouter')) return 'openrouter';
    if (combined.contains('bedrock') || combined.contains('aws')) return 'bedrock';
    if (combined.contains('azure')) return 'azure';

    return 'unknown';
  }

  @override
  Widget build(BuildContext context) {
    final brand = resolveBrandKey(
      providerId: providerId,
      displayName: displayName,
      modelName: modelName,
    );

    final svgData = _brandSvgs[brand];
    if (svgData != null) {
      return SizedBox(
        width: size,
        height: size,
        child: SvgPicture.string(
          svgData,
          width: size,
          height: size,
          fit: BoxFit.contain,
        ),
      );
    }

    // Fallback icon - neutral theme grey instead of primary
    return Icon(
      Symbols.memory,
      size: size,
      color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
    );
  }

  // Authentic brand vector SVG definitions
  static const Map<String, String> _brandSvgs = {
    // Kimi (Moonshot AI) - Dark circle badge with the official stylized white Kimi K
    'kimi': '''
<svg viewBox="0 0 100 100" fill="none" xmlns="http://www.w3.org/2000/svg">
  <circle cx="50" cy="50" r="50" fill="#18181B"/>
  <path d="M34 26V74M34 50H46L66 74M46 50L64 26" stroke="#FFFFFF" stroke-width="11" stroke-linecap="round" stroke-linejoin="round"/>
</svg>
''',

    // OpenCode - Official terminal box with bracket chevron
    'opencode': '''
<svg viewBox="0 0 100 100" fill="none" xmlns="http://www.w3.org/2000/svg">
  <rect x="10" y="10" width="80" height="80" rx="20" fill="#18181B" stroke="#52525B" stroke-width="7"/>
  <path d="M34 38L23 50L34 62M66 38L77 50L66 62M54 32L46 68" stroke="#FAFAFA" stroke-width="8" stroke-linecap="round" stroke-linejoin="round"/>
</svg>
''',

    // Anthropic Claude - Official warm terracotta 8-pointed starburst
    'claude': '''
<svg viewBox="0 0 100 100" fill="none" xmlns="http://www.w3.org/2000/svg">
  <g fill="#D97757">
    <rect x="43" y="6" width="14" height="88" rx="7"/>
    <rect x="6" y="43" width="88" height="14" rx="7"/>
    <rect x="43" y="6" width="14" height="88" rx="7" transform="rotate(45 50 50)"/>
    <rect x="43" y="6" width="14" height="88" rx="7" transform="rotate(-45 50 50)"/>
  </g>
</svg>
''',

    // OpenAI / ChatGPT - Official rosette emblem
    'openai': '''
<svg viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
  <path d="M9.205 8.658v-2.26c0-.19.072-.333.238-.428l4.543-2.616c.619-.357 1.356-.523 2.117-.523 2.854 0 4.662 2.212 4.662 4.566 0 .167 0 .357-.024.547l-4.71-2.759a.797.797 0 00-.856 0l-5.97 3.473zm10.609 8.8V12.06c0-.333-.143-.57-.429-.737l-5.97-3.473 1.95-1.118a.433.433 0 01.476 0l4.543 2.617c1.309.76 2.189 2.378 2.189 3.948 0 1.808-1.07 3.473-2.76 4.163zM7.802 12.703l-1.95-1.142c-.167-.095-.239-.238-.239-.428V5.899c0-2.545 1.95-4.472 4.591-4.472 1 0 1.927.333 2.712.928L8.23 5.067c-.285.166-.428.404-.428.737v6.898zM12 15.128l-2.795-1.57v-3.33L12 8.658l2.795 1.57v3.33L12 15.128zm1.796 7.23c-1 0-1.927-.332-2.712-.927l4.686-2.712c.285-.166.428-.404.428-.737v-6.898l1.974 1.142c.167.095.238.238.238.428v5.233c0 2.545-1.974 4.472-4.614 4.472zm-5.637-5.303l-4.544-2.617c-1.308-.761-2.188-2.378-2.188-3.948A4.482 4.482 0 014.21 6.327v5.423c0 .333.143.571.428.738l5.947 3.449-1.95 1.118a.432.432 0 01-.476 0zm-.262 3.9c-2.688 0-4.662-2.021-4.662-4.519 0-.19.024-.38.047-.57l4.686 2.71c.286.167.571.167.856 0l5.97-3.448v2.26c0 .19-.07.333-.237.428l-4.543 2.616c-.619.357-1.356.523-2.117.523zm5.899 2.83a5.947 5.947 0 005.827-4.756C22.287 18.339 24 15.84 24 13.296c0-1.665-.713-3.282-1.998-4.448.119-.5.19-.999.19-1.498 0-3.401-2.759-5.947-5.946-5.946-.642 0-1.26.095-1.88.31A5.962 5.962 0 0010.205 0a5.947 5.947 0 00-5.827 4.757C1.713 5.447 0 7.945 0 10.49c0 1.666.713 3.283 1.998 4.448-.119.5-.19 1-.19 1.499 0 3.401 2.759 5.946 5.946 5.946.642 0 1.26-.095 1.88-.309a5.96 5.96 0 004.162 1.713z" fill="#FFFFFF" fill-rule="evenodd"/>
</svg>
''',

    // DeepSeek - Official DeepSeek blue whale / dolphin
    'deepseek': '''
<svg viewBox="0 0 100 100" fill="none" xmlns="http://www.w3.org/2000/svg">
  <path d="M14 52C21 31 45 21 72 25C84 27 90 34 88 43C86 53 75 61 62 64C48 67 32 63 25 71C21 76 23 84 27 89C18 83 12 72 13 61C13 57 14 54 14 52Z" fill="#1D63ED"/>
  <path d="M42 41C48 37 60 37 70 42C62 47 50 49 42 47C38 46 38 43 42 41Z" fill="#60A5FA"/>
  <circle cx="75" cy="37" r="4.5" fill="#FFFFFF"/>
</svg>
''',

    // Qwen (Alibaba) - Official Qwen purple Mobius knot
    'qwen': '''
<svg viewBox="0 0 100 100" fill="none" xmlns="http://www.w3.org/2000/svg">
  <path d="M50 14L82 32V68L50 86L18 68V32L50 14Z" stroke="#615CED" stroke-width="10" stroke-linejoin="round" fill="none"/>
  <path d="M50 30L68 41V60L50 70L32 60V41L50 30Z" fill="#615CED" fill-opacity="0.3"/>
  <path d="M50 14V30M82 32L68 41M82 68L68 60M50 86V70M18 68L32 60M18 32L32 41" stroke="#615CED" stroke-width="8"/>
</svg>
''',

    // Meta (Llama) - Official Meta blue infinity loop
    'meta': '''
<svg viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
  <path d="M6.897 4c1.915 0 3.516.932 5.43 3.376l.282-.373c.19-.246.383-.484.58-.71l.313-.35C14.588 4.788 15.792 4 17.225 4c1.273 0 2.469.557 3.491 1.516l.218.213c1.73 1.765 2.917 4.71 3.053 8.026l.011.392.002.25c0 1.501-.28 2.759-.818 3.7l-.14.23-.108.153c-.301.42-.664.758-1.086 1.009l-.265.142-.087.04a3.493 3.493 0 01-.302.118 4.117 4.117 0 01-1.33.208c-.524 0-.996-.067-1.438-.215-.614-.204-1.163-.56-1.726-1.116l-.227-.235c-.753-.812-1.534-1.976-2.493-3.586l-1.43-2.41-.544-.895-1.766 3.13-.343.592C7.597 19.156 6.227 20 4.356 20c-1.21 0-2.205-.42-2.936-1.182l-.168-.184c-.484-.573-.837-1.311-1.043-2.189l-.067-.32a8.69 8.69 0 01-.136-1.288L0 14.468c.002-.745.06-1.49.174-2.23l.1-.573c.298-1.53.828-2.958 1.536-4.157l.209-.34c1.177-1.83 2.789-3.053 4.615-3.16L6.897 4zm-.033 2.615l-.201.01c-.83.083-1.606.673-2.252 1.577l-.138.199-.01.018c-.67 1.017-1.185 2.378-1.456 3.845l-.004.022a12.591 12.591 0 00-.207 2.254l.002.188c.004.18.017.36.04.54l.043.291c.092.503.257.908.486 1.208l.117.137c.303.323.698.492 1.17.492 1.1 0 1.796-.676 3.696-3.641l2.175-3.4.454-.701-.139-.198C9.11 7.3 8.084 6.616 6.864 6.616zm10.196-.552l-.176.007c-.635.048-1.223.359-1.82.933l-.196.198c-.439.462-.887 1.064-1.367 1.807l.266.398c.18.274.362.56.55.858l.293.475 1.396 2.335.695 1.114c.583.926 1.03 1.6 1.408 2.082l.213.262c.282.326.529.54.777.673l.102.05c.227.1.457.138.718.138.176.002.35-.023.518-.073.338-.104.61-.32.813-.637l.095-.163.077-.162c.194-.459.29-1.06.29-1.785l-.006-.449c-.08-2.871-.938-5.372-2.2-6.798l-.176-.189c-.67-.683-1.444-1.074-2.27-1.074z" fill="#0081FB" fill-rule="evenodd"/>
</svg>
''',

    // NVIDIA NIM - Official NVIDIA claw logo
    'nvidia': '''
<svg viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
  <path d="M10.212 8.976V7.62c.127-.01.256-.017.388-.021 3.596-.117 5.957 3.184 5.957 3.184s-2.548 3.647-5.282 3.647a3.227 3.227 0 01-1.063-.175v-4.109c1.4.174 1.681.812 2.523 2.258l1.873-1.627a4.905 4.905 0 00-3.67-1.846 6.594 6.594 0 00-.729.044m0-4.476v2.025c.13-.01.259-.019.388-.024 5.002-.174 8.261 4.226 8.261 4.226s-3.743 4.69-7.643 4.69c-.338 0-.675-.031-1.007-.092v1.25c.278.038.558.057.838.057 3.629 0 6.253-1.91 8.794-4.169.421.347 2.146 1.193 2.501 1.564-2.416 2.083-8.048 3.763-11.24 3.763-.308 0-.603-.02-.894-.048V19.5H24v-15H10.21zm0 9.756v1.068c-3.356-.616-4.287-4.21-4.287-4.21a7.173 7.173 0 014.287-2.138v1.172h-.005a3.182 3.182 0 00-2.502 1.178s.615 2.276 2.507 2.931m-5.961-3.3c1.436-1.935 3.604-3.148 5.961-3.336V6.523C5.81 6.887 2 10.723 2 10.723s2.158 6.427 8.21 7.015v-1.166C5.77 16 4.25 10.958 4.25 10.958h-.002z" fill="#76B900" fill-rule="nonzero"/>
</svg>
''',

    // Z-AI (Zhipu AI / GLM) - Official Z.ai vector
    'zai': '''
<svg viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
  <path d="M12.105 2L9.927 4.953H.653L2.83 2h9.276zM23.254 19.048L21.078 22h-9.242l2.174-2.952h9.244zM24 2L9.264 22H0L14.736 2H24z" fill="#1F63EC" fill-rule="evenodd"/>
</svg>
''',

    // Google Gemini - Official Google 4-point sparkle gradient
    'gemini': '''
<svg viewBox="0 0 100 100" fill="none" xmlns="http://www.w3.org/2000/svg">
  <path d="M50 0C50 27.6 27.6 50 0 50C27.6 50 50 72.4 50 100C50 72.4 72.4 50 100 50C72.4 50 50 27.6 50 0Z" fill="url(#gemini_grad)"/>
  <defs>
    <linearGradient id="gemini_grad" x1="0" y1="50" x2="100" y2="50" gradientUnits="userSpaceOnUse">
      <stop offset="0%" stop-color="#1A73E8"/>
      <stop offset="50%" stop-color="#7C3AED"/>
      <stop offset="100%" stop-color="#EC4899"/>
    </linearGradient>
  </defs>
</svg>
''',

    // Mistral AI - Official orange/red stacked block chevrons
    'mistral': '''
<svg viewBox="0 0 100 100" fill="none" xmlns="http://www.w3.org/2000/svg">
  <rect x="12" y="15" width="22" height="18" rx="4" fill="#FD531E"/>
  <rect x="66" y="15" width="22" height="18" rx="4" fill="#FD531E"/>
  <rect x="12" y="38" width="40" height="18" rx="4" fill="#FD531E"/>
  <rect x="48" y="38" width="40" height="18" rx="4" fill="#FD531E"/>
  <rect x="22" y="61" width="56" height="18" rx="4" fill="#FD531E"/>
</svg>
''',

    // Ollama - Official llama silhouette
    'ollama': '''
<svg viewBox="0 0 100 100" fill="none" xmlns="http://www.w3.org/2000/svg">
  <path d="M38 18C38 15 41 12 44 12C47 12 49 14 50 17L51 25H60C66 25 71 30 71 36V45L77 50C80 52 82 56 82 60V82C82 85 79 88 76 88H68C65 88 62 85 62 82V76H48V82C48 85 45 88 42 88H34C31 88 28 85 28 82V56C28 48 33 42 40 40V24L38 18Z" fill="#F4F4F5"/>
  <circle cx="62" cy="35" r="3.5" fill="#18181B"/>
</svg>
''',

    // GitHub Copilot - Copilot purple helmet
    'copilot': '''
<svg viewBox="0 0 100 100" fill="none" xmlns="http://www.w3.org/2000/svg">
  <path d="M50 16C28 16 18 32 18 48C18 62 25 70 33 76L35 84L45 80C47 80 48 80 50 80C52 80 53 80 55 80L65 84L67 76C75 70 82 62 82 48C82 32 72 16 50 16Z" fill="#7C3AED"/>
  <ellipse cx="36" cy="48" rx="6" ry="8" fill="#FFFFFF"/>
  <ellipse cx="64" cy="48" rx="6" ry="8" fill="#FFFFFF"/>
</svg>
''',

    // Groq - Groq orange circle with G
    'groq': '''
<svg viewBox="0 0 100 100" fill="none" xmlns="http://www.w3.org/2000/svg">
  <circle cx="50" cy="50" r="46" fill="#F55036"/>
  <path d="M52 26C38 26 28 36 28 50C28 64 38 74 52 74C62 74 70 68 73 60H52V48H86C87 52 87 56 87 60C87 76 72 86 52 86C32 86 16 70 16 50C16 30 32 14 52 14C66 14 77 21 82 31L70 39C66 31 60 26 52 26Z" fill="#FFFFFF"/>
</svg>
''',

    // OpenRouter - Hub symbol
    'openrouter': '''
<svg viewBox="0 0 100 100" fill="none" xmlns="http://www.w3.org/2000/svg">
  <circle cx="50" cy="50" r="16" fill="#6366F1"/>
  <circle cx="20" cy="30" r="10" fill="#6366F1"/>
  <circle cx="80" cy="30" r="10" fill="#6366F1"/>
  <circle cx="20" cy="70" r="10" fill="#6366F1"/>
  <circle cx="80" cy="70" r="10" fill="#6366F1"/>
  <path d="M50 50L20 30M50 50L80 30M50 50L20 70M50 50L80 70" stroke="#6366F1" stroke-width="6"/>
</svg>
''',
  };
}
