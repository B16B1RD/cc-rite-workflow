// frame-step renderer: シーン HTML の全アニメーションを pause し、仮想時計を 1/fps ずつ
// seek しながら screenshot して ffmpeg へ流し込む。
//
// 実時間録画（screencast 系 API）を使わないのは、同一入力から md5 まで一致する mp4 を
// 得るため。実時間録画はフレーム到達時刻が実行環境の負荷に依存するので、この性質は
// 原理的に得られない。契約と環境前提は DESIGN.md を参照。
import { chromium } from 'playwright-core';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { existsSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const WIDTH = 1280;
const HEIGHT = 720;
const SCREENSHOT_ATTEMPTS = 3;
const SCREENSHOT_RETRY_MS = 150;

const [, , sceneArg, outArg, fpsArg] = process.argv;
if (!sceneArg || !outArg) {
  console.error('usage: node render/render.mjs <scene.html> <out.mp4> [fps]');
  process.exit(1);
}

const fps = Number(fpsArg ?? 30);
if (!Number.isFinite(fps) || fps <= 0) {
  console.error(`render: fps が正の数値ではありません: ${fpsArg}`);
  process.exit(1);
}

// Chrome は存在しないファイルでもエラーページを描画して load を完了させる。この検査が無いと
// 「真っ白な mp4 が正常終了で生成される」silent failure になる（ffmpeg は成功してしまう）。
const scenePath = resolve(sceneArg);
if (!existsSync(scenePath)) {
  console.error(`render: シーンが見つかりません: ${scenePath}`);
  process.exit(1);
}

const chromePath = process.env.CHROME_PATH ?? '/usr/bin/google-chrome';
if (!existsSync(chromePath)) {
  console.error(`render: Chrome が見つかりません: ${chromePath}（CHROME_PATH で上書きできます）`);
  process.exit(1);
}

const outPath = resolve(outArg);
mkdirSync(dirname(outPath), { recursive: true });

// ffmpeg / browser は try の外で宣言する。ループ内で throw したとき finally から解放できないと、
// stdin の EOF を待ち続ける子プロセスが event loop を保持し、エラーを出したままプロセスが
// 終了しない（exit code が呼び出し元へ届かず check-determinism.sh が無限に待つ）。
let ffmpeg = null;
let browser = null;

try {
  // WSL2 実測: GPU 経路（SwiftShader）はフレーム内容が揺らぎ、screenshot 自体も散発的に失敗する。
  // software rasterizer に固定して決定論を確保する。
  try {
    browser = await chromium.launch({ executablePath: chromePath, args: ['--disable-gpu'] });
  } catch (error) {
    // Playwright の message は起動引数と call log を丸ごと抱えて 17 行になる。1 行目が原因で
    // 残りは定型の再掲なので、他の環境不足経路と同じ 1 行に揃える。
    throw new Error(
      `Chrome の起動に失敗しました: ${error.message.split('\n', 1)[0]}（sandbox 外で実行してください）`,
    );
  }

  const page = await browser.newPage({
    viewport: { width: WIDTH, height: HEIGHT },
    deviceScaleFactor: 1,
  });
  await page.goto(pathToFileURL(scenePath).href, { waitUntil: 'load' });
  // フォント未ロードのままフレームを撮ると初期フレームだけ字形が変わり、決定論が崩れる。
  await page.evaluate(() => document.fonts.ready.then(() => true));

  const declaration = await page.evaluate(() => {
    // pause 済みの Animation を後続の seek 用に保持する。document.getAnimations() を
    // フレームごとに呼び直すと、途中で追加された Animation が混ざり再現性が落ちる。
    window.__riteAnimations = document.getAnimations();
    for (const animation of window.__riteAnimations) animation.pause();

    if (typeof window.SCENE === 'undefined' || window.SCENE === null) return { status: 'missing' };
    const declared = window.SCENE.duration_ms;
    if (typeof declared !== 'number' || !Number.isFinite(declared) || declared <= 0) {
      return { status: 'invalid', repr: String(declared) };
    }
    return { status: 'ok', durationMs: declared };
  });

  if (declaration.status === 'missing') {
    throw new Error(`${sceneArg}: window.SCENE が宣言されていません（既定尺で続行しません）`);
  }
  if (declaration.status === 'invalid') {
    throw new Error(
      `${sceneArg}: window.SCENE.duration_ms が正の数値ではありません: ${declaration.repr}`,
    );
  }

  const frames = Math.round((declaration.durationMs / 1000) * fps);

  ffmpeg = spawn(
    'ffmpeg',
    [
      '-y', '-f', 'image2pipe', '-framerate', String(fps), '-i', '-',
      '-c:v', 'libx264', '-preset', 'medium', '-crf', '18',
      '-pix_fmt', 'yuv420p',
      // 実行時刻がコンテナに載ると同一入力でも md5 が変わるため落とす。
      '-map_metadata', '-1',
      outPath,
    ],
    { stdio: ['pipe', 'ignore', 'inherit'] },
  );

  // 起動失敗（ENOENT 等）と書き込み中断は非同期で表面化する。listener が無いと 'error' が
  // 未処理例外になるため、最初の 1 件を保持して終了検査で報告する。
  let ffmpegFailure = null;
  ffmpeg.on('error', (error) => {
    ffmpegFailure ??= `ffmpeg を起動できませんでした: ${error.message}`;
  });
  ffmpeg.stdin.on('error', (error) => {
    ffmpegFailure ??= `ffmpeg への書き込みが中断されました: ${error.message}`;
  });

  // close 済みかをループ条件に使う。死んだ子プロセスへ残りのフレームを撮り続けない。
  let closed = null;
  const ffmpegClosed = new Promise((settle) => {
    ffmpeg.on('close', (code, signal) => settle((closed = { code, signal })));
  });

  for (let index = 0; index < frames && !closed; index += 1) {
    const timeMs = (index * 1000) / fps;
    await page.evaluate((ms) => {
      for (const animation of window.__riteAnimations) animation.currentTime = ms;
    }, timeMs);

    let buffer = null;
    let lastError = null;
    for (let attempt = 1; attempt <= SCREENSHOT_ATTEMPTS; attempt += 1) {
      try {
        buffer = await page.screenshot({ type: 'png' });
        break;
      } catch (error) {
        lastError = error;
        // リトライは黙って飲まない。SwiftShader の揺らぎは頻度が上がると決定論そのものを疑う
        // 材料になるため、成功して終わった回も痕跡を残す。
        console.error(
          `render: フレーム ${index}/${frames} の screenshot に失敗しました（${attempt}/${SCREENSHOT_ATTEMPTS} 回目）: ${error.message}`,
        );
        await new Promise((r) => setTimeout(r, SCREENSHOT_RETRY_MS));
      }
    }
    if (buffer === null) {
      throw new Error(
        `フレーム ${index}/${frames} の screenshot が ${SCREENSHOT_ATTEMPTS} 回連続で失敗しました: ${lastError?.message}`,
      );
    }

    // screenshot を待つ間に ffmpeg が死ぬと drain は二度と来ない。close と競わせて待ちを解く。
    if (!ffmpeg.stdin.write(buffer)) {
      await Promise.race([once(ffmpeg.stdin, 'drain'), ffmpegClosed]);
    }
  }

  ffmpeg.stdin.end();
  const { code, signal } = await ffmpegClosed;
  if (ffmpegFailure) throw new Error(ffmpegFailure);
  if (code !== 0) {
    throw new Error(`ffmpeg が ${signal ? `signal ${signal}` : `exit code ${code}`} で終了しました`);
  }

  console.log(`rendered ${frames} frames @${fps}fps -> ${outPath}`);
} catch (error) {
  console.error(`render: ${error.message}`);
  process.exitCode = 1;
} finally {
  // 成功経路では既に close 済みで no-op。失敗経路では stdin を閉じて子プロセスを落とし、
  // event loop を空にして exit code を呼び出し元へ返す。
  if (ffmpeg) {
    ffmpeg.stdin.destroy();
    ffmpeg.kill();
  }
  if (browser) await browser.close();
}
