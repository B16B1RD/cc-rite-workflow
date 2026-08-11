// frame-step renderer: シーン HTML の全アニメーションを pause し、仮想時計を 1/fps ずつ
// seek しながら screenshot して ffmpeg へ流し込む。
//
// 実時間録画（screencast 系 API）を使わないのは、同一入力から md5 まで一致する mp4 を
// 得るため。実時間録画はフレーム到達時刻が実行環境の負荷に依存するので、この性質は
// 原理的に得られない。契約と環境前提は DESIGN.md を参照。
import { chromium } from 'playwright-core';
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const WIDTH = 1280;
const HEIGHT = 720;
const SCREENSHOT_ATTEMPTS = 3;
const SCREENSHOT_RETRY_MS = 150;

// 想定内の契約違反・環境不足はスタックトレース無しで簡潔に落とす。
// 想定外の例外だけスタックを出したいので riteExpected で区別する。
function fail(message) {
  const error = new Error(message);
  error.riteExpected = true;
  throw error;
}

function usage() {
  console.error('usage: node render/render.mjs <scene.html> <out.mp4> [fps]');
  process.exit(1);
}

const [, , sceneArg, outArg, fpsArg] = process.argv;
if (!sceneArg || !outArg) usage();

const fps = Number(fpsArg ?? 30);
if (!Number.isFinite(fps) || fps <= 0) {
  console.error(`render: fps が正の数値ではありません: ${fpsArg}`);
  process.exit(1);
}

// file:// の存在チェックを goto より先に置く。Chrome は存在しないファイルでも
// エラーページを描画して load を完了させるため、これが無いと「真っ白な mp4 が
// 正常終了で生成される」silent failure になる。
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

// WSL2 実測: GPU 経路（SwiftShader）はフレーム内容が揺らぎ、screenshot 自体も散発的に失敗する。
// software rasterizer に固定して決定論を確保する。
const browser = await chromium.launch({ executablePath: chromePath, args: ['--disable-gpu'] });

// ffmpeg は try の外で宣言する。ループ内で throw したとき finally から解放できないと、
// stdin の EOF を待ち続ける子プロセスが event loop を保持し、エラーを出したままプロセスが
// 終了しない（exit code が呼び出し元へ届かず check-determinism.sh が無限に待つ）。
let ffmpeg = null;

try {
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

    if (typeof window.SCENE === 'undefined' || window.SCENE === null) {
      return { status: 'missing' };
    }
    const declared = window.SCENE.duration_ms;
    if (typeof declared !== 'number' || !Number.isFinite(declared) || declared <= 0) {
      return { status: 'invalid', repr: String(declared) };
    }
    return { status: 'ok', durationMs: declared };
  });

  if (declaration.status === 'missing') {
    fail(`${sceneArg}: window.SCENE が宣言されていません（既定尺で続行しません）`);
  }
  if (declaration.status === 'invalid') {
    fail(`${sceneArg}: window.SCENE.duration_ms が正の数値ではありません: ${declaration.repr}`);
  }

  const frames = Math.round((declaration.durationMs / 1000) * fps);
  if (frames < 1) {
    fail(`宣言尺 ${declaration.durationMs}ms × ${fps}fps ではフレームが 1 枚も生成されません`);
  }

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

  // ffmpeg 側の異常は書き込み中に非同期で表面化する。取りこぼすと「途中で切れた mp4 が
  // 正常終了で残る」ため、最初の 1 件を保持してフレームループ内で検査する。
  let ffmpegFailure = null;
  let ffmpegExitCode = null;
  ffmpeg.on('error', (error) => {
    ffmpegFailure ??= `ffmpeg の起動に失敗しました: ${error.message}`;
  });
  ffmpeg.stdin.on('error', (error) => {
    ffmpegFailure ??= `ffmpeg への書き込みが中断されました: ${error.message}`;
  });
  const ffmpegClosed = new Promise((resolvePromise) => {
    ffmpeg.on('close', (code) => {
      ffmpegExitCode = code;
      resolvePromise(code);
    });
  });

  for (let index = 0; index < frames; index += 1) {
    if (ffmpegFailure) fail(ffmpegFailure);
    if (ffmpegExitCode !== null) {
      fail(`ffmpeg がフレーム ${index}/${frames} の時点で exit code ${ffmpegExitCode} で終了しました`);
    }

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
        await new Promise((r) => setTimeout(r, SCREENSHOT_RETRY_MS));
      }
    }
    if (buffer === null) {
      fail(
        `フレーム ${index}/${frames} の screenshot が ${SCREENSHOT_ATTEMPTS} 回連続で失敗しました: ${lastError?.message}`,
      );
    }

    if (!ffmpeg.stdin.write(buffer)) {
      // ffmpeg が死んでいると drain は永久に来ない。close も待って hang を防ぐ
      // （どちらで抜けたかは次の周回の failure 検査が判定する）。
      // 決着した側だけが once で外れるため、負けた listener を明示的に外す。
      // 放置すると backpressure の回数だけ close listener が積み上がり、11 本目で
      // MaxListenersExceededWarning が ffmpeg の stderr と同じ経路に混ざる。
      await new Promise((r) => {
        const settle = () => {
          ffmpeg.stdin.off('drain', settle);
          ffmpeg.off('close', settle);
          r();
        };
        ffmpeg.stdin.once('drain', settle);
        ffmpeg.once('close', settle);
      });
    }
  }

  ffmpeg.stdin.end();
  const exitCode = await ffmpegClosed;
  if (ffmpegFailure) fail(ffmpegFailure);
  if (exitCode !== 0) fail(`ffmpeg が exit code ${exitCode} で終了しました`);

  // 「宣言尺どおりのフレーム数」を推測ではなく出力から確かめる。ffmpeg は入力が途中で
  // 尽きても exit 0 で短い mp4 を残せるので、ここを飛ばすと欠落が検出できない。
  const probe = spawnSync(
    'ffprobe',
    [
      '-v', 'error', '-select_streams', 'v:0', '-count_packets',
      '-show_entries', 'stream=nb_read_packets', '-of', 'csv=p=0', outPath,
    ],
    { encoding: 'utf8' },
  );
  if (probe.error) fail(`ffprobe の実行に失敗しました: ${probe.error.message}`);
  if (probe.status !== 0) fail(`ffprobe が exit code ${probe.status} で終了しました: ${probe.stderr.trim()}`);
  const written = Number(probe.stdout.trim());
  if (written !== frames) {
    fail(`出力フレーム数が宣言尺と一致しません（期待 ${frames} / 実際 ${written}）: ${outPath}`);
  }

  console.log(`rendered ${frames} frames @${fps}fps -> ${outPath}`);
} catch (error) {
  console.error(`render: ${error.message}`);
  if (!error.riteExpected) console.error(error.stack);
  process.exitCode = 1;
} finally {
  // 成功経路では既に close 済みで no-op。失敗経路では stdin を閉じて子プロセスを落とし、
  // event loop を空にして exit code を呼び出し元へ返す。
  if (ffmpeg) {
    ffmpeg.stdin.destroy();
    ffmpeg.kill();
  }
  await browser.close();
}
