"use strict";

const PLAYER_ID = "alice";
const AUTH_HEADERS = { Authorization: "Bearer local-alice" };

const elements = {
  form: document.querySelector("#quiz-form"),
  questions: document.querySelector("#questions"),
  answeredCount: document.querySelector("#answered-count"),
  progressBar: document.querySelector("#progress-bar"),
  saveState: document.querySelector("#save-state"),
  submitButton: document.querySelector("#submit-button"),
  latestScore: document.querySelector("#latest-score"),
  latestDetail: document.querySelector("#latest-detail"),
  resultPanel: document.querySelector("#result-panel"),
  resultScore: document.querySelector("#result-score"),
  resultMessage: document.querySelector("#result-message"),
  resultCorrect: document.querySelector("#result-correct"),
  resultVersion: document.querySelector("#result-version"),
  resultTime: document.querySelector("#result-time"),
  retryButton: document.querySelector("#retry-button"),
  fatalError: document.querySelector("#fatal-error"),
  fatalMessage: document.querySelector("#fatal-message"),
  reloadButton: document.querySelector("#reload-button"),
};

let quiz = null;
let player = null;
let submitting = false;

class ApiFailure extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

async function request(pathname, options = {}) {
  const response = await fetch(pathname, {
    ...options,
    headers: { ...AUTH_HEADERS, ...(options.headers || {}) },
  });
  let payload;
  try {
    payload = await response.json();
  } catch (_error) {
    throw new ApiFailure(response.status, "INVALID_RESPONSE", "서버 응답 형식을 확인할 수 없습니다.");
  }
  if (!response.ok) {
    const error = payload && payload.error ? payload.error : {};
    throw new ApiFailure(response.status, error.code || "REQUEST_FAILED", error.message || "요청에 실패했습니다.");
  }
  return payload;
}

function setStatus(message, isError = false) {
  elements.saveState.textContent = message;
  elements.saveState.classList.toggle("is-error", isError);
}

function updateLatest(value) {
  player = value;
  if (!value.latest_result) {
    elements.latestScore.textContent = "첫 도전";
    elements.latestDetail.textContent = "아직 저장된 점수가 없습니다.";
    return;
  }
  elements.latestScore.textContent = String(value.score) + "점";
  elements.latestDetail.textContent =
    String(value.latest_result.correct_count) + " / " +
    String(value.latest_result.question_count) + " 정답 · 기록 #" + String(value.version);
}

function renderQuestions(value) {
  const letters = ["A", "B", "C", "D"];
  elements.questions.replaceChildren();
  value.questions.forEach((question, questionIndex) => {
    const card = document.createElement("article");
    card.className = "question-card";
    card.dataset.question = String(questionIndex);

    const heading = document.createElement("div");
    heading.className = "question-heading";

    const number = document.createElement("span");
    number.className = "question-number";
    number.textContent = "Q" + String(questionIndex + 1).padStart(2, "0");

    const copy = document.createElement("div");
    const domain = document.createElement("p");
    domain.className = "domain";
    domain.textContent = question.domain;
    const title = document.createElement("h2");
    title.id = "question-" + String(questionIndex);
    title.textContent = question.text;
    copy.append(domain, title);
    heading.append(number, copy);

    const choices = document.createElement("div");
    choices.className = "choices";
    choices.setAttribute("role", "radiogroup");
    choices.setAttribute("aria-labelledby", title.id);

    question.choices.forEach((choice, choiceIndex) => {
      const label = document.createElement("label");
      label.className = "choice";
      const input = document.createElement("input");
      input.type = "radio";
      input.name = "answer-" + String(questionIndex);
      input.value = String(choiceIndex);
      input.required = true;
      const key = document.createElement("span");
      key.className = "choice-key";
      key.textContent = letters[choiceIndex];
      const text = document.createElement("span");
      text.textContent = choice;
      label.append(input, key, text);
      choices.append(label);
    });

    card.append(heading, choices);
    elements.questions.append(card);
  });
}

function selectedAnswers() {
  if (!quiz) return [];
  return quiz.questions.map((_question, index) => {
    const selected = elements.form.querySelector('input[name="answer-' + String(index) + '"]:checked');
    return selected ? Number(selected.value) : null;
  });
}

function updateProgress() {
  const answered = selectedAnswers().filter((answer) => answer !== null).length;
  const total = quiz ? quiz.question_count : 10;
  elements.answeredCount.textContent = String(answered);
  elements.progressBar.style.width = String(Math.round((answered / total) * 100)) + "%";
  elements.submitButton.disabled = submitting || answered !== total;
  if (!submitting) {
    setStatus(answered === total ? "제출할 준비가 됐습니다." : String(total - answered) + "문제가 남았습니다.");
  }
}

function makeId(prefix) {
  const random = crypto.getRandomValues(new Uint32Array(2));
  return prefix + "-" + Date.now().toString(36) + "-" +
    random[0].toString(36) + random[1].toString(36);
}

function formatTime(iso) {
  return new Intl.DateTimeFormat("ko-KR", {
    dateStyle: "medium", timeStyle: "short",
  }).format(new Date(iso));
}

function showResult(result) {
  elements.resultScore.textContent = String(result.score);
  elements.resultCorrect.textContent =
    String(result.correct_count) + " / " + String(result.question_count) + " 정답";
  elements.resultVersion.textContent = "기록 #" + String(result.version);
  elements.resultTime.textContent = formatTime(result.recorded_at);
  elements.resultMessage.textContent = result.score >= 80
    ? "요구사항 사이의 우선순위를 잘 구분했습니다."
    : "오답은 서비스 이름보다 RPO, 순서, 권한, 운영 부담을 기준으로 다시 비교해 보세요.";
  elements.resultPanel.hidden = false;
  elements.form.hidden = true;
  elements.resultPanel.scrollIntoView({ behavior: "smooth", block: "center" });
}

async function load() {
  elements.fatalError.hidden = true;
  elements.form.hidden = true;
  elements.resultPanel.hidden = true;
  setStatus("문제와 최근 기록을 불러오는 중입니다.");
  try {
    const values = await Promise.all([
      request("/quiz"), request("/players/" + PLAYER_ID),
    ]);
    quiz = values[0];
    updateLatest(values[1]);
    renderQuestions(quiz);
    elements.form.hidden = false;
    updateProgress();
  } catch (error) {
    elements.fatalMessage.textContent = error instanceof ApiFailure
      ? error.message + " (" + error.code + ")"
      : "로컬 서버가 실행 중인지 확인하세요.";
    elements.fatalError.hidden = false;
    setStatus("불러오기에 실패했습니다.", true);
  }
}

elements.form.addEventListener("change", updateProgress);
elements.form.addEventListener("submit", async (event) => {
  event.preventDefault();
  const answers = selectedAnswers();
  if (!quiz || answers.some((answer) => answer === null) || submitting) return;

  submitting = true;
  elements.submitButton.disabled = true;
  setStatus("서버가 답안을 채점하고 저장하는 중입니다.");
  try {
    const result = await request("/players/" + PLAYER_ID + "/results", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        event_id: makeId("ui-event"),
        quiz_id: quiz.quiz_id,
        expected_version: player.version,
        answers,
        test_run_id: makeId("ui-run"),
      }),
    });
    updateLatest({
      player_id: PLAYER_ID,
      score: result.score,
      version: result.version,
      latest_result: result,
    });
    setStatus("점수와 이벤트가 저장됐습니다.");
    showResult(result);
  } catch (error) {
    if (error instanceof ApiFailure && error.code === "VERSION_CONFLICT") {
      try {
        updateLatest(await request("/players/" + PLAYER_ID));
        setStatus("다른 제출이 먼저 저장되어 최신 기록을 불러왔습니다. 답안을 확인하고 다시 제출하세요.", true);
      } catch (_reloadError) {
        setStatus("버전 충돌 후 최신 기록을 불러오지 못했습니다.", true);
      }
    } else {
      setStatus(error instanceof ApiFailure
        ? error.message + " (" + error.code + ")"
        : "서버 연결을 확인한 뒤 다시 제출하세요.", true);
    }
  } finally {
    submitting = false;
    elements.submitButton.disabled = selectedAnswers().some((answer) => answer === null);
  }
});

elements.retryButton.addEventListener("click", async () => {
  elements.resultPanel.hidden = true;
  elements.form.reset();
  elements.form.hidden = false;
  try {
    updateLatest(await request("/players/" + PLAYER_ID));
    updateProgress();
    window.scrollTo({ top: elements.form.offsetTop - 100, behavior: "smooth" });
  } catch (_error) {
    setStatus("최신 기록을 불러오지 못했습니다. 페이지를 새로고침하세요.", true);
  }
});

elements.reloadButton.addEventListener("click", load);
load();
