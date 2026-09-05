// ==============================================
// GLOBAL APPLICATION STATE
// ==============================================
let currentRole = 'student';
let teacherToken = sessionStorage.getItem('teacher_token') || null;
let currentTeacherTab = 'checklist';

let allAssignments = [];
let allStudents = [];
let currentChecklistAssignmentId = null;
let currentChecklistData = null;

let currentClassFilter = '';
let currentStatusFilter = 'all';
let currentSearchQuery = '';

// Selected file for submission
let selectedFile = null;

// ==============================================
// INITIALIZATION
// ==============================================
document.addEventListener('DOMContentLoaded', () => {
  initDragAndDrop();
  initAuthUI();
  loadInitialData();
});

function initAuthUI() {
  const teacherBadge = document.getElementById('teacherAuthBadge');
  const sessionControls = document.getElementById('teacherSessionControls');
  
  if (teacherToken) {
    if (teacherBadge) teacherBadge.style.display = 'inline-block';
    if (sessionControls) sessionControls.style.display = 'flex';
  } else {
    if (teacherBadge) teacherBadge.style.display = 'none';
    if (sessionControls) sessionControls.style.display = 'none';
  }
}

async function loadInitialData() {
  await fetchAssignments();
  await fetchStudentsList();
}

// ==============================================
// ROLE SWITCHING & AUTHENTICATION
// ==============================================
function switchRole(role) {
  if (role === 'teacher') {
    if (!teacherToken) {
      openTeacherLoginModal();
      return;
    }
    setRoleActive('teacher');
  } else {
    setRoleActive('student');
  }
}

function setRoleActive(role) {
  currentRole = role;
  const btnStudent = document.getElementById('btnRoleStudent');
  const btnTeacher = document.getElementById('btnRoleTeacher');
  const studentView = document.getElementById('studentView');
  const teacherView = document.getElementById('teacherView');

  if (role === 'student') {
    btnStudent.classList.add('active');
    btnTeacher.classList.remove('active');
    studentView.classList.add('active');
    teacherView.classList.remove('active');
    fetchAssignments();
  } else {
    btnTeacher.classList.add('active');
    btnStudent.classList.remove('active');
    teacherView.classList.add('active');
    studentView.classList.remove('active');
    
    // Switch to active tab (default checklist)
    switchTeacherTab(currentTeacherTab);
    fetchStats();
  }
}

// Teacher Login Modal Controls
function openTeacherLoginModal() {
  const modal = document.getElementById('teacherLoginModal');
  const input = document.getElementById('teacherPasswordInput');
  const errorMsg = document.getElementById('loginErrorMessage');
  
  if (errorMsg) errorMsg.style.display = 'none';
  if (input) {
    input.value = '';
    setTimeout(() => input.focus(), 150);
  }
  if (modal) modal.classList.add('active');
}

function closeTeacherLoginModal() {
  const modal = document.getElementById('teacherLoginModal');
  if (modal) modal.classList.remove('active');
}

async function handleTeacherLogin(e) {
  e.preventDefault();
  const input = document.getElementById('teacherPasswordInput');
  const errorMsg = document.getElementById('loginErrorMessage');
  const btnSubmit = document.getElementById('btnTeacherLoginSubmit');
  const form = document.getElementById('teacherLoginForm');

  const password = input.value.trim();
  if (!password) return;

  btnSubmit.disabled = true;
  btnSubmit.innerHTML = 'กำลังตรวจสอบ...';

  try {
    const res = await fetch('/api/auth/teacher', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ password: password })
    });

    const data = await res.json();

    if (res.ok && data.success) {
      teacherToken = data.token;
      sessionStorage.setItem('teacher_token', teacherToken);
      
      initAuthUI();
      closeTeacherLoginModal();
      setRoleActive('teacher');
      showToast('เข้าสู่ระบบสำหรับอาจารย์สำเร็จ 🎉', 'success');
    } else {
      errorMsg.textContent = data.error || 'รหัสผ่านไม่ถูกต้อง กรุณาลองใหม่อีกครั้ง';
      errorMsg.style.display = 'block';
      
      // Add shake animation
      form.classList.add('shake');
      setTimeout(() => form.classList.remove('shake'), 400);
      input.select();
    }
  } catch (err) {
    console.error(err);
    errorMsg.textContent = 'ไม่สามารถเชื่อมต่อเซิร์ฟเวอร์ได้';
    errorMsg.style.display = 'block';
  } finally {
    btnSubmit.disabled = false;
    btnSubmit.innerHTML = '<span>เข้าสู่ระบบ (Login)</span><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="5" y1="12" x2="19" y2="12"></line><polyline points="12 5 19 12 12 19"></polyline></svg>';
  }
}

function logoutTeacher() {
  teacherToken = null;
  sessionStorage.removeItem('teacher_token');
  initAuthUI();
  setRoleActive('student');
  showToast('ออกจากระบบอาจารย์เรียบร้อยแล้ว', 'info');
}

function togglePasswordVisibility(inputId, btn) {
  const input = document.getElementById(inputId);
  if (!input) return;
  if (input.type === 'password') {
    input.type = 'text';
    btn.innerHTML = `<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19m-6.72-1.07a3 3 0 1 1-4.24-4.24"></path><line x1="1" y1="1" x2="23" y2="23"></line></svg>`;
  } else {
    input.type = 'password';
    btn.innerHTML = `<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"></path><circle cx="12" cy="12" r="3"></circle></svg>`;
  }
}

// Helper to get authenticated headers
function getAuthHeaders() {
  const headers = { 'Content-Type': 'application/json' };
  if (teacherToken) {
    headers['Authorization'] = `Bearer ${teacherToken}`;
    headers['X-Teacher-Token'] = teacherToken;
  }
  return headers;
}

// ==============================================
// TEACHER SUB-TABS SWITCHING
// ==============================================
function switchTeacherTab(tabName) {
  currentTeacherTab = tabName;

  document.querySelectorAll('.teacher-tab-btn').forEach(btn => btn.classList.remove('active'));
  document.querySelectorAll('.tab-content-panel').forEach(panel => panel.classList.remove('active'));

  if (tabName === 'checklist') {
    document.getElementById('tabBtnChecklist').classList.add('active');
    document.getElementById('teacherTabContentChecklist').classList.add('active');
    loadChecklistTab();
  } else if (tabName === 'assignments') {
    document.getElementById('tabBtnAssignments').classList.add('active');
    document.getElementById('teacherTabContentAssignments').classList.add('active');
    fetchAssignments();
    fetchStats();
  } else if (tabName === 'students') {
    document.getElementById('tabBtnStudents').classList.add('active');
    document.getElementById('teacherTabContentStudents').classList.add('active');
    fetchStudentsList();
  }
}

// ==============================================
// DATA FETCHING & API CALLS
// ==============================================
async function fetchAssignments() {
  try {
    const res = await fetch('/api/assignments');
    if (!res.ok) throw new Error('ไม่สามารถโหลดข้อมูลงานได้');
    allAssignments = await res.json();

    // Update Counts
    const countBadge = document.getElementById('studentAssignmentCount');
    if (countBadge) countBadge.textContent = `${allAssignments.length} งาน`;
    
    const tabCount = document.getElementById('tabCountAssignments');
    if (tabCount) tabCount.textContent = allAssignments.length;

    renderStudentView();
    renderTeacherAssignmentsTable();

    // If on checklist tab and no assignment chosen, choose the first one
    if (allAssignments.length > 0 && !currentChecklistAssignmentId) {
      currentChecklistAssignmentId = allAssignments[0].id;
    }
  } catch (err) {
    console.error(err);
    showToast(err.message, 'error');
  }
}

async function fetchStats() {
  try {
    const res = await fetch('/api/stats');
    if (!res.ok) return;
    const stats = await res.json();
    
    if (document.getElementById('statAssignments')) document.getElementById('statAssignments').textContent = stats.assignments_count || 0;
    if (document.getElementById('statSubmissions')) document.getElementById('statSubmissions').textContent = stats.submissions_count || 0;
    if (document.getElementById('statPending')) document.getElementById('statPending').textContent = stats.pending_count || 0;
    if (document.getElementById('statGraded')) document.getElementById('statGraded').textContent = stats.graded_count || 0;
  } catch (err) {
    console.error(err);
  }
}

async function fetchStudentsList() {
  try {
    const res = await fetch('/api/students');
    if (!res.ok) throw new Error('ไม่สามารถโหลดรายชื่อนักเรียนได้');
    const data = await res.json();
    allStudents = data.students || [];

    const rosterBadge = document.getElementById('rosterCountBadge');
    if (rosterBadge) rosterBadge.textContent = `${allStudents.length} คน`;

    const tabCount = document.getElementById('tabCountStudents');
    if (tabCount) tabCount.textContent = allStudents.length;

    renderStudentsTable();
  } catch (err) {
    console.error(err);
  }
}

// ==============================================
// TAB 1: ตารางเช็คงานนักเรียน (STUDENT CHECKLIST)
// ==============================================
async function loadChecklistTab() {
  if (allAssignments.length === 0) {
    await fetchAssignments();
  }
  populateChecklistAssignmentDropdown();
  if (currentChecklistAssignmentId) {
    await fetchChecklistData(currentChecklistAssignmentId, currentClassFilter);
  }
}

function populateChecklistAssignmentDropdown() {
  const select = document.getElementById('checklistAssignmentSelect');
  if (!select) return;

  if (allAssignments.length === 0) {
    select.innerHTML = '<option value="">ยังไม่มีรายการงานที่สร้างไว้</option>';
    return;
  }

  select.innerHTML = allAssignments.map(a => `
    <option value="${a.id}" ${a.id === currentChecklistAssignmentId ? 'selected' : ''}>
      ${escapeHtml(a.subject)} - ${escapeHtml(a.title)} (คะแนนเต็ม ${a.max_score})
    </option>
  `).join('');
}

function handleChecklistAssignmentChange() {
  const select = document.getElementById('checklistAssignmentSelect');
  currentChecklistAssignmentId = parseInt(select.value, 10);
  fetchChecklistData(currentChecklistAssignmentId, currentClassFilter);
}

async function fetchChecklistData(assignmentId, classroom = '') {
  const tableBody = document.getElementById('checklistTableBody');
  tableBody.innerHTML = `<tr><td colspan="9" class="text-center py-5">กำลังโหลดข้อมูลตารางเช็คงาน...</td></tr>`;

  try {
    const url = `/api/assignments/${assignmentId}/checklist?classroom=${encodeURIComponent(classroom)}`;
    const res = await fetch(url);
    if (!res.ok) throw new Error('ไม่สามารถโหลดตารางเช็คงานได้');
    
    currentChecklistData = await res.json();
    
    renderChecklistHeaderDetails(currentChecklistData.assignment);
    renderChecklistStats(currentChecklistData.stats);
    populateClassroomFilter(currentChecklistData.classrooms);
    updateExportCsvLink(assignmentId, classroom);
    renderChecklistTable();
  } catch (err) {
    console.error(err);
    tableBody.innerHTML = `<tr><td colspan="9" class="text-center py-5 text-red">เกิดข้อผิดพลาด: ${err.message}</td></tr>`;
  }
}

function renderChecklistHeaderDetails(assign) {
  const container = document.getElementById('checklistAssignmentDetails');
  if (!container || !assign) return;

  const dueInfo = calculateTimeRemaining(assign.due_date);

  container.innerHTML = `
    <div class="detail-pill">
      <span>วิชา:</span>
      <strong>${escapeHtml(assign.subject)}</strong>
    </div>
    <div class="detail-pill">
      <span>คะแนนเต็ม:</span>
      <strong>${assign.max_score} คะแนน</strong>
    </div>
    <div class="detail-pill">
      <span>กำหนดส่ง:</span>
      <strong>${formatThaiDateTime(assign.due_date)}</strong>
    </div>
    <div class="detail-pill ${dueInfo.colorClass}">
      <span>${dueInfo.icon} ${dueInfo.text}</span>
    </div>
  `;
}

function renderChecklistStats(stats) {
  if (!stats) return;

  document.getElementById('checkStatTotal').textContent = stats.total_students || 0;
  document.getElementById('checkStatSubmitted').textContent = stats.submitted_count || 0;
  document.getElementById('checkStatRate').textContent = `${stats.submission_rate}% ของทั้งหมด`;
  
  document.getElementById('checkStatMissing').textContent = stats.missing_count || 0;
  const missingRate = stats.total_students > 0 ? (100 - stats.submission_rate).toFixed(1) : 0;
  document.getElementById('checkStatMissingRate').textContent = `${missingRate}% ยังไม่ส่ง`;

  document.getElementById('checkStatGraded').textContent = stats.graded_count || 0;
  const gradedRate = stats.submitted_count > 0 ? ((stats.graded_count / stats.submitted_count) * 100).toFixed(0) : 0;
  document.getElementById('checkStatGradedRate').textContent = `ตรวจแล้ว ${gradedRate}%`;

  document.getElementById('checkStatAvgScore').textContent = stats.average_score !== null ? stats.average_score : '-';

  // Progress Bar
  const submittedWidth = Math.max(0, stats.submission_rate - (stats.late_count / (stats.total_students || 1) * 100));
  const lateWidth = stats.total_students > 0 ? ((stats.late_count / stats.total_students) * 100) : 0;

  document.getElementById('progressBarSubmitted').style.width = `${submittedWidth}%`;
  document.getElementById('progressBarLate').style.width = `${lateWidth}%`;
  document.getElementById('progressBarPercentLabel').textContent = `${stats.submission_rate}% (ส่งแล้ว ${stats.submitted_count}/${stats.total_students} คน)`;

  // Update Status Pills Count
  document.getElementById('pillCountAll').textContent = stats.total_students;
  document.getElementById('pillCountSubmitted').textContent = stats.submitted_count;
  document.getElementById('pillCountMissing').textContent = stats.missing_count;
  document.getElementById('pillCountGraded').textContent = stats.graded_count;
  document.getElementById('pillCountLate').textContent = stats.late_count;
}

function populateClassroomFilter(classrooms) {
  const select = document.getElementById('filterClassroom');
  if (!select || !classrooms) return;

  const currentVal = select.value;
  select.innerHTML = '<option value="">ทั้งหมดทุกห้อง</option>' + classrooms.map(c => `
    <option value="${escapeHtml(c)}" ${c === currentVal ? 'selected' : ''}>${escapeHtml(c)}</option>
  `).join('');
}

function updateExportCsvLink(assignmentId, classroom) {
  const link = document.getElementById('btnExportChecklistCsv');
  if (link) {
    link.href = `/api/export/checklist/${assignmentId}?classroom=${encodeURIComponent(classroom)}`;
  }
}

function setChecklistStatusFilter(status) {
  currentStatusFilter = status;
  document.querySelectorAll('.status-pill-btn').forEach(btn => {
    btn.classList.toggle('active', btn.dataset.status === status);
  });
  renderChecklistTable();
}

function filterChecklistTable() {
  const select = document.getElementById('filterClassroom');
  currentClassFilter = select ? select.value : '';
  
  const searchInput = document.getElementById('checklistSearchInput');
  currentSearchQuery = searchInput ? searchInput.value.trim().toLowerCase() : '';

  // If classroom filter changed, reload API data
  if (currentChecklistData && select && select.value !== undefined) {
    updateExportCsvLink(currentChecklistAssignmentId, currentClassFilter);
  }
  
  renderChecklistTable();
}

function renderChecklistTable() {
  const tableBody = document.getElementById('checklistTableBody');
  if (!tableBody || !currentChecklistData) return;

  let list = currentChecklistData.students || [];

  // Filter Classroom
  if (currentClassFilter) {
    list = list.filter(s => s.classroom === currentClassFilter);
  }

  // Filter Status
  if (currentStatusFilter !== 'all') {
    if (currentStatusFilter === 'submitted') {
      list = list.filter(s => s.status !== 'missing');
    } else {
      list = list.filter(s => s.status === currentStatusFilter);
    }
  }

  // Filter Search
  if (currentSearchQuery) {
    list = list.filter(s => 
      (s.student_id && s.student_id.toLowerCase().includes(currentSearchQuery)) ||
      (s.student_name && s.student_name.toLowerCase().includes(currentSearchQuery)) ||
      (s.student_number && s.student_number.toString().includes(currentSearchQuery))
    );
  }

  if (list.length === 0) {
    tableBody.innerHTML = `
      <tr>
        <td colspan="9" class="text-center py-5">
          <div class="empty-state">
            <p>ไม่พบรายชื่อนักเรียนตามเงื่อนไขที่เลือก</p>
          </div>
        </td>
      </tr>
    `;
    return;
  }

  tableBody.innerHTML = list.map(student => {
    const isSubmitted = student.status !== 'missing';
    const rowClass = isSubmitted ? 'row-submitted' : 'row-missing';

    // Status Badge
    let statusBadge = '';
    if (student.status === 'graded') {
      statusBadge = `<span class="badge-status badge-graded">⭐ ตรวจแล้ว</span>`;
    } else if (student.status === 'late') {
      statusBadge = `<span class="badge-status badge-late">⏰ ส่งช้า</span>`;
    } else if (student.status === 'submitted') {
      statusBadge = `<span class="badge-status badge-submitted">✅ ส่งแล้ว</span>`;
    } else {
      statusBadge = `<span class="badge-status badge-missing">❌ ยังไม่ส่ง</span>`;
    }

    // Quick toggle button
    const nextStatus = isSubmitted ? 'missing' : 'submitted';
    const toggleBtnText = isSubmitted ? '✅ ส่งแล้ว' : '❌ ยังไม่ส่ง';
    const toggleBtnClass = isSubmitted ? 'is-submitted' : 'is-missing';
    const toggleTooltip = isSubmitted ? 'คลิกเพื่อเปลี่ยนเป็นยังไม่ส่ง' : 'คลิกเพื่อเช็คว่าส่งงานแล้วทันที';

    // Score display
    const scoreDisplay = student.score !== null && student.score !== undefined
      ? `<span class="score-pill">${student.score} / ${currentChecklistData.assignment.max_score}</span>`
      : `<span class="score-none">-</span>`;

    const submittedTimeDisplay = student.submitted_at 
      ? formatTimeOnly(student.submitted_at) 
      : '<span class="text-slate-400">-</span>';

    return `
      <tr class="${rowClass}">
        <td><strong>${student.student_number || '-'}</strong></td>
        <td><span class="student-id-badge">${escapeHtml(student.student_id)}</span></td>
        <td>
          <div class="student-name-cell clickable-student" onclick="openStudentPortfolioModal('${escapeHtml(student.student_id)}', '${escapeHtml(student.classroom)}')" title="คลิกเพื่อดูประวัติงานทุกชิ้นของนักเรียนคนนี้">
            <div class="student-avatar">${getAvatarInitials(student.student_name)}</div>
            <span>${escapeHtml(student.student_name)}</span>
            <span style="font-size: 0.75rem; color: var(--school-green); margin-left: 4px;" title="ดูประวัติงานทุกชิ้น">📋</span>
          </div>
        </td>
        <td><span class="classroom-badge">${escapeHtml(student.classroom || '-')}</span></td>
        <td>${statusBadge}</td>
        <td><small>${submittedTimeDisplay}</small></td>
        <td>${scoreDisplay}</td>
        <td class="text-center">
          <button class="btn-quick-check ${toggleBtnClass}" 
                  onclick="quickToggleSubmission('${escapeHtml(student.student_id)}', '${escapeHtml(student.classroom)}', '${nextStatus}')"
                  title="${toggleTooltip}">
            <span>${toggleBtnText}</span>
          </button>
        </td>
        <td class="text-center">
          <button class="btn btn-sm btn-outline-success" 
                  onclick="openGradeModalForStudent('${escapeHtml(student.student_id)}')">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 20h9"></path><path d="M16.5 3.5a2.121 2.121 0 0 1 3 3L7 19l-4 1 1-4L16.5 3.5z"></path></svg>
            <span>ตรวจงาน</span>
          </button>
        </td>
      </tr>
    `;
  }).join('');
}

// Quick Toggle Submission Status
async function quickToggleSubmission(studentId, classroom, targetStatus) {
  if (!teacherToken) {
    openTeacherLoginModal();
    return;
  }

  try {
    const url = `/api/assignments/${currentChecklistAssignmentId}/checklist/toggle`;
    const res = await fetch(url, {
      method: 'POST',
      headers: getAuthHeaders(),
      body: JSON.stringify({
        student_id: studentId,
        classroom: classroom,
        status: targetStatus
      })
    });

    const data = await res.json();
    if (res.ok && data.success) {
      showToast(data.message || 'บันทึกสถานะเรียบร้อยแล้ว', 'success');
      // Refresh checklist table
      fetchChecklistData(currentChecklistAssignmentId, currentClassFilter);
    } else {
      showToast(data.error || 'ไม่สามารถเปลี่ยนสถานะได้', 'error');
    }
  } catch (err) {
    console.error(err);
    showToast('เกิดข้อผิดพลาดในการเชื่อมต่อ', 'error');
  }
}

// Open Grade Modal for Student
function openGradeModalForStudent(studentId) {
  if (!teacherToken) {
    openTeacherLoginModal();
    return;
  }

  if (!currentChecklistData) return;

  const student = currentChecklistData.students.find(s => s.student_id === studentId);
  if (!student) return;

  const assign = currentChecklistData.assignment;

  document.getElementById('gradeSubmissionId').value = student.submission_id || '';
  document.getElementById('gradeStudentIdHidden').value = student.student_id;
  document.getElementById('gradeAssignmentIdHidden').value = assign.id;

  document.getElementById('gradeStudentName').textContent = student.student_name;
  document.getElementById('gradeStudentId').textContent = student.student_id;
  document.getElementById('gradeClassroom').textContent = student.classroom || '-';
  document.getElementById('gradeMaxScoreDisplay').textContent = assign.max_score;

  document.getElementById('inputScore').value = student.score !== null && student.score !== undefined ? student.score : '';
  document.getElementById('inputScore').max = assign.max_score;
  document.getElementById('inputFeedback').value = student.feedback || '';

  // Submitted content preview
  const detailsBox = document.getElementById('gradeWorkDetailsContent');
  if (student.submission_id) {
    let filesHtml = '';
    if (student.file_name) {
      filesHtml += `
        <div style="margin-bottom: 0.5rem;">
          <strong>📁 ไฟล์ที่แนบ:</strong> 
          <a href="${student.file_path}" target="_blank" class="text-primary" download>
            ${escapeHtml(student.file_name)}
          </a> (${formatBytes(student.file_size || 0)})
        </div>
      `;
    }
    if (student.submission_link) {
      filesHtml += `
        <div style="margin-bottom: 0.5rem;">
          <strong>🔗 ลิงก์แนบ:</strong> 
          <a href="${escapeHtml(student.submission_link)}" target="_blank" class="text-primary" rel="noopener">
            ${escapeHtml(student.submission_link)}
          </a>
        </div>
      `;
    }
    if (student.note) {
      filesHtml += `
        <div>
          <strong>💬 ข้อความจากนักเรียน:</strong> ${escapeHtml(student.note)}
        </div>
      `;
    }
    if (!student.file_name && !student.submission_link && !student.note) {
      filesHtml = '<em>เช็คส่งงานโดยตรงในห้องเรียน</em>';
    }
    detailsBox.innerHTML = filesHtml;
  } else {
    detailsBox.innerHTML = '<span class="text-slate-400">นักเรียนยังไม่ได้ส่งไฟล์ผ่านระบบ (กำลังให้คะแนนจากการตรวจงานในห้อง)</span>';
  }

  openModal('gradeModal');
}

// Handle Save Grade
async function handleSaveGrade(e) {
  e.preventDefault();
  const subId = document.getElementById('gradeSubmissionId').value;
  const stdId = document.getElementById('gradeStudentIdHidden').value;
  const assignId = document.getElementById('gradeAssignmentIdHidden').value;
  const score = parseFloat(document.getElementById('inputScore').value);
  const feedback = document.getElementById('inputFeedback').value.trim();

  try {
    let url = '';
    let method = 'POST';
    let body = {};

    if (subId) {
      url = `/api/submissions/${subId}/grade`;
      body = { score, feedback };
    } else {
      // If student hasn't submitted through portal yet, create submission and grade
      await fetch(`/api/assignments/${assignId}/checklist/toggle`, {
        method: 'POST',
        headers: getAuthHeaders(),
        body: JSON.stringify({ student_id: stdId, status: 'submitted' })
      });
      // Fetch latest to get newly created submission_id
      const chkRes = await fetch(`/api/assignments/${assignId}/checklist`);
      const chkData = await chkRes.json();
      const updatedStd = chkData.students.find(s => s.student_id === stdId);
      if (updatedStd && updatedStd.submission_id) {
        url = `/api/submissions/${updatedStd.submission_id}/grade`;
        body = { score, feedback };
      }
    }

    const res = await fetch(url, {
      method: 'POST',
      headers: getAuthHeaders(),
      body: JSON.stringify(body)
    });

    const data = await res.json();
    if (res.ok && data.success) {
      showToast('บันทึกผลคะแนนและคำติชมสำเร็จ ⭐', 'success');
      closeModal('gradeModal');
      fetchChecklistData(currentChecklistAssignmentId, currentClassFilter);
    } else {
      showToast(data.error || 'ไม่สามารถบันทึกคะแนนได้', 'error');
    }
  } catch (err) {
    console.error(err);
    showToast('เกิดข้อผิดพลาดในการบันทึกคะแนน', 'error');
  }
}

function addFeedbackText(text) {
  const input = document.getElementById('inputFeedback');
  if (input.value) {
    input.value += ' ' + text;
  } else {
    input.value = text;
  }
}

// ==============================================
// TAB 2: TEACHER ASSIGNMENTS MANAGEMENT
// ==============================================
function renderTeacherAssignmentsTable() {
  const tableBody = document.getElementById('teacherAssignmentsTableBody');
  if (!tableBody) return;

  if (allAssignments.length === 0) {
    tableBody.innerHTML = `<tr><td colspan="5" class="text-center py-4">ยังไม่มีรายการงานที่สร้างไว้</td></tr>`;
    return;
  }

  tableBody.innerHTML = allAssignments.map(a => `
    <tr>
      <td>
        <span class="subject-badge mb-1">${escapeHtml(a.subject)}</span>
        <div style="font-weight: 700; font-size: 1rem; color: var(--slate-900); margin-top: 0.2rem;">
          ${escapeHtml(a.title)}
        </div>
      </td>
      <td>${formatThaiDateTime(a.due_date)}</td>
      <td><strong>${a.max_score}</strong> คะแนน</td>
      <td>
        <span class="badge-status badge-submitted">
          ส่งแล้ว ${a.submissions_count || 0} คน
        </span>
      </td>
      <td class="text-center">
        <div class="d-flex justify-between gap-2" style="justify-content: center;">
          <button class="btn btn-sm btn-primary" onclick="openChecklistForAssignment(${a.id})">
            📋 เช็คงาน
          </button>
          <button class="btn btn-sm btn-secondary" onclick="openEditAssignmentModal(${a.id})">
            ✏️ แก้ไข
          </button>
          <button class="btn btn-sm btn-ghost text-red" onclick="handleDeleteAssignment(${a.id})">
            🗑️ ลบ
          </button>
        </div>
      </td>
    </tr>
  `).join('');
}

function openChecklistForAssignment(id) {
  currentChecklistAssignmentId = id;
  switchTeacherTab('checklist');
}

function openCreateAssignmentModal() {
  if (!teacherToken) {
    openTeacherLoginModal();
    return;
  }
  document.getElementById('assignmentModalTitle').textContent = 'สร้างหัวข้องานใหม่';
  document.getElementById('editAssignmentId').value = '';
  document.getElementById('assignSubject').value = '';
  document.getElementById('assignTitle').value = '';
  document.getElementById('assignDesc').value = '';
  document.getElementById('assignMaxScore').value = '100';
  document.getElementById('assignAllowLate').checked = true;

  const now = new Date();
  now.setDate(now.getDate() + 7);
  now.setHours(23, 59, 0, 0);
  document.getElementById('assignDueDate').value = now.toISOString().slice(0, 16);

  openModal('assignmentFormModal');
}

function openEditAssignmentModal(id) {
  if (!teacherToken) {
    openTeacherLoginModal();
    return;
  }
  const assign = allAssignments.find(a => a.id === id);
  if (!assign) return;

  document.getElementById('assignmentModalTitle').textContent = 'แก้ไขหัวข้องาน';
  document.getElementById('editAssignmentId').value = assign.id;
  document.getElementById('assignSubject').value = assign.subject;
  document.getElementById('assignTitle').value = assign.title;
  document.getElementById('assignDesc').value = assign.description || '';
  document.getElementById('assignMaxScore').value = assign.max_score;
  document.getElementById('assignDueDate').value = assign.due_date;
  document.getElementById('assignAllowLate').checked = assign.allow_late === 1;

  openModal('assignmentFormModal');
}

async function handleSaveAssignment(e) {
  e.preventDefault();
  const id = document.getElementById('editAssignmentId').value;
  const payload = {
    subject: document.getElementById('assignSubject').value.trim(),
    title: document.getElementById('assignTitle').value.trim(),
    description: document.getElementById('assignDesc').value.trim(),
    due_date: document.getElementById('assignDueDate').value,
    max_score: parseFloat(document.getElementById('assignMaxScore').value),
    allow_late: document.getElementById('assignAllowLate').checked
  };

  try {
    const url = id ? `/api/assignments/${id}` : '/api/assignments';
    const method = id ? 'PUT' : 'POST';

    const res = await fetch(url, {
      method: method,
      headers: getAuthHeaders(),
      body: JSON.stringify(payload)
    });

    const data = await res.json();
    if (res.ok) {
      showToast(id ? 'แก้ไขหัวข้องานสำเร็จ' : 'สร้างหัวข้องานใหม่เรียบร้อย 🎉', 'success');
      closeModal('assignmentFormModal');
      await fetchAssignments();
      if (!id) currentChecklistAssignmentId = data.id;
    } else {
      showToast(data.error || 'เกิดข้อผิดพลาดในการบันทึกงาน', 'error');
    }
  } catch (err) {
    console.error(err);
    showToast('เกิดข้อผิดพลาดในการเชื่อมต่อ', 'error');
  }
}

async function handleDeleteAssignment(id) {
  if (!teacherToken) {
    openTeacherLoginModal();
    return;
  }
  if (!confirm('คุณแน่ใจหรือไม่ว่าต้องการลบหัวข้องานนี้? ข้อมูลการส่งงานและคะแนนทั้งหมดจะถูกลบไปด้วย')) return;

  try {
    let res = await fetch(`/api/assignments/${id}`, {
      method: 'DELETE',
      headers: getAuthHeaders()
    });

    // If DELETE method failed or 405, fallback to POST /api/assignments/:id/delete
    if (!res.ok) {
      res = await fetch(`/api/assignments/${id}/delete`, {
        method: 'POST',
        headers: getAuthHeaders()
      });
    }

    const data = await res.json().catch(() => ({}));
    if (res.ok && (data.success !== false)) {
      showToast('ลบงานเรียบร้อยแล้ว', 'success');
      await fetchAssignments();
      if (currentChecklistAssignmentId === id) {
        currentChecklistAssignmentId = allAssignments[0]?.id || null;
      }
      loadChecklistTab();
    } else {
      if (res.status === 401) {
        showToast('เซสชันอาจารย์หมดอายุ กรุณาเข้าสู่ระบบใหม่อีกครั้ง', 'warning');
        openTeacherLoginModal();
      } else {
        showToast(data.error || 'ไม่สามารถลบงานได้', 'error');
      }
    }
  } catch (err) {
    console.error(err);
    showToast('เกิดข้อผิดพลาดในการลบงาน', 'error');
  }
}

// ==============================================
// TAB 3: STUDENT ROSTER MANAGEMENT
// ==============================================
function renderStudentsTable() {
  const tableBody = document.getElementById('studentRosterTableBody');
  if (!tableBody) return;

  const roomFilterEl = document.getElementById('rosterFilterClassroom');
  const searchEl = document.getElementById('rosterSearchInput');
  const selectedRoom = roomFilterEl ? roomFilterEl.value : '';
  const searchQuery = searchEl ? searchEl.value.trim().toLowerCase() : '';

  let list = allStudents || [];

  if (selectedRoom) {
    list = list.filter(std => std.classroom === selectedRoom);
  }

  if (searchQuery) {
    list = list.filter(std => 
      (std.name && std.name.toLowerCase().includes(searchQuery)) ||
      (std.student_id && std.student_id.toLowerCase().includes(searchQuery))
    );
  }

  const rosterBadge = document.getElementById('rosterCountBadge');
  if (rosterBadge) {
    if (selectedRoom || searchQuery) {
      rosterBadge.textContent = `${list.length} / ${allStudents.length} คน`;
    } else {
      rosterBadge.textContent = `${allStudents.length} คน`;
    }
  }

  if (list.length === 0) {
    tableBody.innerHTML = `<tr><td colspan="5" class="text-center py-4">ไม่พบรายชื่อนักเรียนตามเงื่อนไขที่เลือก</td></tr>`;
    return;
  }

  tableBody.innerHTML = list.map(std => `
    <tr>
      <td><strong>${std.student_number || '-'}</strong></td>
      <td><span class="student-id-badge">${escapeHtml(std.student_id)}</span></td>
      <td>
        <div class="student-name-cell clickable-student" onclick="openStudentPortfolioModal('${escapeHtml(std.student_id)}', '${escapeHtml(std.classroom)}')" title="คลิกเพื่อดูประวัติงานทุกชิ้นของนักเรียนคนนี้">
          <div class="student-avatar">${getAvatarInitials(std.name)}</div>
          <span>${escapeHtml(std.name)}</span>
          <span style="font-size: 0.75rem; color: var(--school-green); margin-left: 4px;" title="ดูประวัติงานทุกชิ้น">📋</span>
        </div>
      </td>
      <td><span class="classroom-badge">${escapeHtml(std.classroom)}</span></td>
      <td class="text-center">
        <button class="btn btn-sm btn-ghost text-red" onclick="handleDeleteStudent(${std.id})">
          🗑️ ลบ
        </button>
      </td>
    </tr>
  `).join('');
}

function openAddStudentModal() {
  if (!teacherToken) {
    openTeacherLoginModal();
    return;
  }
  document.getElementById('inputStdNumber').value = allStudents.length + 1;
  document.getElementById('inputStdClassroom').value = 'ม.5/1';
  document.getElementById('inputStdId').value = '';
  document.getElementById('inputStdName').value = '';
  openModal('addStudentModal');
}

async function handleSaveStudent(e) {
  e.preventDefault();
  const payload = {
    student_number: parseInt(document.getElementById('inputStdNumber').value, 10),
    classroom: document.getElementById('inputStdClassroom').value.trim(),
    student_id: document.getElementById('inputStdId').value.trim(),
    name: document.getElementById('inputStdName').value.trim()
  };

  try {
    const res = await fetch('/api/students', {
      method: 'POST',
      headers: getAuthHeaders(),
      body: JSON.stringify(payload)
    });

    const data = await res.json();
    if (res.ok && data.success) {
      showToast('เพิ่มรายชื่อนักเรียนสำเร็จ 🎉', 'success');
      closeModal('addStudentModal');
      await fetchStudentsList();
    } else {
      showToast(data.error || 'ไม่สามารถเพิ่มนักเรียนได้', 'error');
    }
  } catch (err) {
    console.error(err);
    showToast('เกิดข้อผิดพลาดในการเชื่อมต่อ', 'error');
  }
}

async function handleDeleteStudent(id) {
  if (!teacherToken) {
    openTeacherLoginModal();
    return;
  }
  if (!confirm('ยืนยันลบรายชื่อนักเรียนคนนี้?')) return;

  try {
    let res = await fetch(`/api/students/${id}`, {
      method: 'DELETE',
      headers: getAuthHeaders()
    });

    if (!res.ok) {
      res = await fetch(`/api/students/${id}/delete`, {
        method: 'POST',
        headers: getAuthHeaders()
      });
    }

    const data = await res.json().catch(() => ({}));
    if (res.ok && (data.success !== false)) {
      showToast('ลบรายชื่อนักเรียนแล้ว', 'success');
      await fetchStudentsList();
    } else {
      if (res.status === 401) {
        showToast('เซสชันอาจารย์หมดอายุ กรุณาเข้าสู่ระบบใหม่อีกครั้ง', 'warning');
        openTeacherLoginModal();
      } else {
        showToast(data.error || 'ไม่สามารถลบข้อมูลนักเรียนได้', 'error');
      }
    }
  } catch (err) {
    console.error(err);
    showToast('เกิดข้อผิดพลาดในการลบนักเรียน', 'error');
  }
}

// ==============================================
// STUDENT VIEW RENDERING & SUBMISSION FLOW
// ==============================================
function renderStudentView() {
  const container = document.getElementById('studentAssignmentsList');
  if (!container) return;

  if (allAssignments.length === 0) {
    container.innerHTML = `<div class="empty-state" style="grid-column: 1/-1;">ยังไม่มีรายการงานที่เปิดรับในขณะนี้</div>`;
    return;
  }

  container.innerHTML = allAssignments.map(assign => {
    const dueInfo = calculateTimeRemaining(assign.due_date);
    const isPastDue = dueInfo.isPast;
    const canSubmit = !isPastDue || assign.allow_late === 1;

    return `
      <div class="assignment-card">
        <div class="card-top">
          <span class="subject-badge">${escapeHtml(assign.subject)}</span>
          <span class="due-ticker ${dueInfo.colorClass}">
            ${dueInfo.icon} ${dueInfo.text}
          </span>
        </div>
        <h4 class="assignment-title">${escapeHtml(assign.title)}</h4>
        <p class="assignment-desc">${escapeHtml(assign.description || 'ไม่มีรายละเอียดเพิ่มเติม')}</p>
        
        <div class="assignment-meta-row">
          <div class="meta-item">
            <span>คะแนนเต็ม:</span>
            <strong>${assign.max_score} คะแนน</strong>
          </div>
          <div class="meta-item">
            <span>ส่งแล้ว:</span>
            <strong>${assign.submissions_count || 0} คน</strong>
          </div>
        </div>

        <button class="btn btn-primary btn-block" onclick="openSubmitModal(${assign.id})" ${canSubmit ? '' : 'disabled'}>
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="22" y1="2" x2="11" y2="13"></line><polygon points="22 2 15 22 11 13 2 9 22 2"></polygon></svg>
          <span>${canSubmit ? 'ส่งงาน / การบ้านนี้' : 'ปิดรับการส่งแล้ว'}</span>
        </button>
      </div>
    `;
  }).join('');
}

function filterStudentAssignments() {
  const query = document.getElementById('studentSearchInput').value.toLowerCase().trim();
  const cards = document.querySelectorAll('#studentAssignmentsList .assignment-card');

  cards.forEach(card => {
    const title = card.querySelector('.assignment-title').textContent.toLowerCase();
    const subject = card.querySelector('.subject-badge').textContent.toLowerCase();
    if (title.includes(query) || subject.includes(query)) {
      card.style.display = 'flex';
    } else {
      card.style.display = 'none';
    }
  });
}

function openSubmitModal(assignmentId, prefillSid = '', prefillCls = '', prefillName = '') {
  const assign = allAssignments.find(a => a.id === assignmentId);
  if (!assign) return;

  document.getElementById('submitAssignmentId').value = assign.id;
  document.getElementById('submitModalTitle').textContent = `ส่งงาน: ${assign.title}`;
  
  const dueInfo = calculateTimeRemaining(assign.due_date);
  document.getElementById('submitAssignmentInfo').innerHTML = `
    <strong>รายวิชา:</strong> ${escapeHtml(assign.subject)} | 
    <strong>คะแนนเต็ม:</strong> ${assign.max_score} คะแนน | 
    <strong>กำหนดส่ง:</strong> ${formatThaiDateTime(assign.due_date)} 
    <span class="badge ${dueInfo.colorClass}" style="margin-left: 0.5rem;">${dueInfo.text}</span>
  `;

  // Reset inputs
  document.getElementById('submitWorkForm').reset();
  removeSelectedFile();

  if (prefillSid) {
    document.getElementById('studentId').value = prefillSid;
  }
  if (prefillName) {
    document.getElementById('studentName').value = prefillName;
  }
  if (prefillCls) {
    document.getElementById('studentClassroom').value = prefillCls;
  } else if (prefillSid) {
    handleStudentIdBlur(prefillSid);
  }

  openModal('submitWorkModal');
}

// Auto fill student name if known in roster
function handleStudentIdBlur(studentId) {
  const trimmed = studentId.trim();
  if (!trimmed || allStudents.length === 0) return;

  const found = allStudents.find(s => s.student_id === trimmed);
  if (found) {
    const nameInput = document.getElementById('studentName');
    if (nameInput && (!nameInput.value || nameInput.value.trim() === '')) {
      nameInput.value = found.name;
    }
    const clsSelect = document.getElementById('studentClassroom');
    if (clsSelect && (!clsSelect.value || clsSelect.value === 'ม.5/1')) {
      clsSelect.value = found.classroom;
    }
  }
}

// Student submits work
async function handleWorkSubmit(e) {
  e.preventDefault();
  const form = document.getElementById('submitWorkForm');
  const btnSubmit = document.getElementById('btnSubmitWork');
  const formData = new FormData(form);

  const fileInput = document.getElementById('fileInput');
  const linkInput = document.getElementById('submissionLink');
  const noteInput = document.getElementById('studentNote');

  if ((!fileInput.files || fileInput.files.length === 0) && !linkInput.value.trim() && !noteInput.value.trim()) {
    showToast('กรุณาแนบไฟล์ผลงาน หรือกรอกลิงก์ผลงานอย่างน้อย 1 อย่าง', 'warning');
    return;
  }

  btnSubmit.disabled = true;
  btnSubmit.innerHTML = 'กำลังอัปโหลดและส่งงาน...';

  try {
    const res = await fetch('/api/submissions', {
      method: 'POST',
      body: formData
    });

    const data = await res.json();
    if (res.ok && data.success) {
      showToast('🎉 ส่งงานเรียบร้อยแล้ว!', 'success');
      closeModal('submitWorkModal');
      fetchAssignments();

      const sub = data.submission || {};
      const stdId = sub.student_id || formData.get('student_id');
      const stdCls = sub.classroom || formData.get('classroom');
      const assignId = sub.assignment_id || parseInt(formData.get('assignment_id'));

      // POP UP the comprehensive student portfolio checklist!
      setTimeout(() => {
        openStudentPortfolioModal(stdId, stdCls, assignId);
      }, 300);
    } else {
      showToast(data.error || 'เกิดข้อผิดพลาดในการส่งงาน', 'error');
    }
  } catch (err) {
    console.error(err);
    showToast('ไม่สามารถเชื่อมต่อเซิร์ฟเวอร์ได้', 'error');
  } finally {
    btnSubmit.disabled = false;
    btnSubmit.innerHTML = `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="22" y1="2" x2="11" y2="13"></line><polygon points="22 2 15 22 11 13 2 9 22 2"></polygon></svg><span>ยืนยันการส่งงาน</span>`;
  }
}

// Student Tracking Modal
function openMySubmissionsModal() {
  document.getElementById('trackStudentIdInput').value = '';
  document.getElementById('mySubmissionsResults').innerHTML = `
    <div class="empty-state">
      <p>กรุณากรอกรหัสประจำตัว หรือชื่อนักเรียน เพื่อเปิดดูประวัติและสถานะการส่งงานทุกชิ้น</p>
    </div>
  `;
  openModal('mySubmissionsModal');
}

async function searchMySubmissions() {
  const studentId = document.getElementById('trackStudentIdInput').value.trim();
  if (!studentId) {
    showToast('กรุณากรอกรหัสประจำตัวหรือชื่อนักเรียนเพื่อค้นหา', 'warning');
    return;
  }
  closeModal('mySubmissionsModal');
  openStudentPortfolioModal(studentId);
}

// Comprehensive Student Assignment Portfolio & Checklist Modal
async function openStudentPortfolioModal(studentId, classroom = '', justSubmittedAssignmentId = null) {
  if (!studentId) return;

  const successBanner = document.getElementById('portfolioSuccessBanner');
  const profileCard = document.getElementById('portfolioProfileCard');
  const progressText = document.getElementById('portfolioProgressText');
  const progressBar = document.getElementById('portfolioProgressBar');
  const itemsContainer = document.getElementById('portfolioItemsContainer');
  const classroomLabel = document.getElementById('portfolioClassroomLabel');

  // Reset modal state
  if (justSubmittedAssignmentId) {
    successBanner.style.display = 'flex';
    document.getElementById('portfolioSuccessMessage').textContent = 'บันทึกชิ้นงานและการส่งเข้าสู่ระบบแล้ว ตรวจสอบสถานะงานทั้งหมดด้านล่างได้เลย';
  } else {
    successBanner.style.display = 'none';
  }

  itemsContainer.innerHTML = '<div class="text-center py-5 text-muted"><div class="spinner"></div> กำลังดึงข้อมูลประวัติการส่งงาน...</div>';
  openModal('studentPortfolioModal');

  try {
    const url = `/api/students/portfolio?student_id=${encodeURIComponent(studentId)}&classroom=${encodeURIComponent(classroom || '')}`;
    const res = await fetch(url);
    const data = await res.json();

    if (!res.ok) {
      itemsContainer.innerHTML = `<div class="alert alert-danger">${escapeHtml(data.error || 'ไม่สามารถโหลดข้อมูลได้')}</div>`;
      return;
    }

    if (data.multiple) {
      // Multiple students matched
      itemsContainer.innerHTML = `
        <div class="card p-4 text-center">
          <h5>พบรายชื่อนักเรียนที่มีรหัสตรงกัน ${data.candidates.length} คน</h5>
          <p class="text-muted text-sm mt-1">กรุณาเลือกห้องเรียนที่ถูกต้อง:</p>
          <div class="d-flex justify-center gap-2 mt-3 flex-wrap">
            ${data.candidates.map(c => `
              <button class="btn btn-outline-success" onclick="openStudentPortfolioModal('${escapeHtml(c.student_id)}', '${escapeHtml(c.classroom)}', ${justSubmittedAssignmentId || 'null'})">
                ห้อง ${escapeHtml(c.classroom)} - ${escapeHtml(c.name)} (เลขที่ ${c.student_number})
              </button>
            `).join('')}
          </div>
        </div>
      `;
      return;
    }

    const student = data.student;
    const stats = data.stats;
    const items = data.items;

    // 1. Render Student Profile
    profileCard.innerHTML = `
      <div class="portfolio-student-info">
        <div class="portfolio-avatar">${getAvatarInitials(student.name)}</div>
        <div class="portfolio-details">
          <h3>${escapeHtml(student.name)}</h3>
          <div class="portfolio-meta-tags">
            <span class="portfolio-tag tag-id">รหัส: <strong>${escapeHtml(student.student_id)}</strong></span>
            <span class="portfolio-tag tag-classroom">ห้อง: <strong>${escapeHtml(student.classroom)}</strong></span>
            <span class="portfolio-tag">เลขที่: <strong>${student.student_number || '-'}</strong></span>
          </div>
        </div>
      </div>
      <div class="text-right d-none-mobile">
        <div style="font-size: 0.8rem; color: var(--slate-500);">คะแนนสะสมที่ได้</div>
        <div style="font-size: 1.35rem; font-weight: 800; color: var(--school-green-dark);">
          ${stats.total_score_earned} <span style="font-size: 0.85rem; font-weight: 500; color: var(--slate-400);">/ ${stats.total_max_score}</span>
        </div>
      </div>
    `;

    // 2. Render Progress Bar
    const pct = stats.progress_pct || 0;
    progressBar.style.width = `${pct}%`;
    progressText.textContent = `ส่งแล้ว ${stats.submitted_count} / ${stats.total_assignments} งาน (${pct}%)`;

    if (classroomLabel) {
      classroomLabel.textContent = `นักเรียนห้อง ${student.classroom}`;
    }

    // 3. Render Items List
    if (items.length === 0) {
      itemsContainer.innerHTML = '<div class="text-center py-4 text-muted">ยังไม่มีรายการงานในระบบ</div>';
      return;
    }

    itemsContainer.innerHTML = items.map((item, idx) => {
      const isJustSubmitted = justSubmittedAssignmentId && item.assignment_id === justSubmittedAssignmentId;
      const cardClass = item.submitted 
        ? (isJustSubmitted ? 'portfolio-item-card is-just-submitted' : 'portfolio-item-card is-submitted')
        : 'portfolio-item-card is-missing';

      let statusBadgeHtml = '';
      if (item.submitted) {
        if (item.status === 'graded') {
          statusBadgeHtml = `<span class="badge-status badge-graded">⭐ ตรวจแล้ว (${item.submission.score} / ${item.max_score} คะแนน)</span>`;
        } else if (item.status === 'late') {
          statusBadgeHtml = `<span class="badge-status badge-late">⏰ ส่งแล้ว (ส่งช้า)</span>`;
        } else {
          statusBadgeHtml = `<span class="badge-status badge-submitted">✅ ส่งงานเรียบร้อยแล้ว</span>`;
        }
      } else {
        statusBadgeHtml = `<span class="badge-status badge-missing">❌ ยังไม่ได้ส่ง</span>`;
      }

      return `
        <div class="${cardClass}">
          <div class="portfolio-item-header">
            <div>
              <span class="portfolio-item-subject">${escapeHtml(item.subject)}</span>
              <h4 class="portfolio-item-title mt-1">ชิ้นที่ ${idx + 1}: ${escapeHtml(item.title)}</h4>
            </div>
            <div>
              ${statusBadgeHtml}
            </div>
          </div>

          <div class="d-flex justify-between align-center text-sm" style="color: var(--slate-500);">
            <div>
              <span>กำหนดส่ง: <strong>${formatThaiDateTime(item.due_date)}</strong></span>
              <span style="margin-left: 0.5rem;">| คะแนนเต็ม: <strong>${item.max_score} คะแนน</strong></span>
            </div>
            ${!item.submitted ? `
              <button class="btn btn-sm btn-primary" onclick="closeModal('studentPortfolioModal'); openSubmitModal(${item.assignment_id}, '${escapeHtml(student.student_id)}', '${escapeHtml(student.classroom)}', '${escapeHtml(student.name)}')">
                📤 ส่งงานนี้เลย
              </button>
            ` : ''}
          </div>

          ${item.submitted && item.submission ? `
            <div class="portfolio-submission-info">
              <div class="d-flex justify-between align-center">
                <span>🕒 วันเวลาที่ส่ง: <strong>${formatThaiDateTime(item.submission.submitted_at)}</strong></span>
                ${teacherToken ? `
                  <button class="btn btn-sm btn-outline-success" onclick="closeModal('studentPortfolioModal'); openGradeModalForStudent('${escapeHtml(student.student_id)}')">
                    ✏️ ตรวจ/ให้คะแนน
                  </button>
                ` : ''}
              </div>

              <div class="mt-2 d-flex gap-2 flex-wrap align-center">
                ${item.submission.file_path ? `
                  <a href="${item.submission.file_path}" target="_blank" class="portfolio-file-attachment">
                    📄 <span>${escapeHtml(item.submission.file_name || 'ดาวน์โหลดไฟล์ผลงาน')}</span>
                  </a>
                ` : ''}
                ${item.submission.submission_link ? `
                  <a href="${item.submission.submission_link}" target="_blank" class="portfolio-file-attachment" style="color: var(--primary);">
                    🔗 <span>เปิดดูผลงาน (${escapeHtml(item.submission.submission_link)})</span>
                  </a>
                ` : ''}
                ${item.submission.note ? `
                  <span class="text-xs text-muted">💬 บันทึก: "${escapeHtml(item.submission.note)}"</span>
                ` : ''}
              </div>

              ${item.submission.feedback ? `
                <div class="portfolio-feedback-box">
                  <strong>💬 ความเห็น/คำติชมจากอาจารย์:</strong> ${escapeHtml(item.submission.feedback)}
                </div>
              ` : ''}
            </div>
          ` : ''}
        </div>
      `;
    }).join('');

  } catch (err) {
    console.error(err);
    itemsContainer.innerHTML = '<div class="alert alert-danger">เกิดข้อผิดพลาดในการเชื่อมต่อเซิร์ฟเวอร์</div>';
  }
}

// ==============================================
// DRAG AND DROP FILE UPLOADER
// ==============================================
function initDragAndDrop() {
  const dropZone = document.getElementById('dropZone');
  const fileInput = document.getElementById('fileInput');
  if (!dropZone || !fileInput) return;

  dropZone.addEventListener('click', (e) => {
    if (!e.target.closest('.btn-remove-file')) {
      fileInput.click();
    }
  });

  ['dragenter', 'dragover'].forEach(event => {
    dropZone.addEventListener(event, (e) => {
      e.preventDefault();
      e.stopPropagation();
      dropZone.classList.add('dragover');
    });
  });

  ['dragleave', 'drop'].forEach(event => {
    dropZone.addEventListener(event, (e) => {
      e.preventDefault();
      e.stopPropagation();
      dropZone.classList.remove('dragover');
    });
  });

  dropZone.addEventListener('drop', (e) => {
    if (e.dataTransfer.files && e.dataTransfer.files.length > 0) {
      fileInput.files = e.dataTransfer.files;
      handleFileSelected(fileInput);
    }
  });
}

function handleFileSelected(input) {
  if (!input.files || input.files.length === 0) return;
  const file = input.files[0];
  selectedFile = file;

  document.getElementById('dropZonePrompt').style.display = 'none';
  const preview = document.getElementById('filePreviewCard');
  preview.style.display = 'flex';
  document.getElementById('previewFileName').textContent = file.name;
  document.getElementById('previewFileSize').textContent = formatBytes(file.size);
}

function removeSelectedFile() {
  const input = document.getElementById('fileInput');
  if (input) input.value = '';
  selectedFile = null;
  const prompt = document.getElementById('dropZonePrompt');
  const preview = document.getElementById('filePreviewCard');
  if (prompt) prompt.style.display = 'block';
  if (preview) preview.style.display = 'none';
}

// ==============================================
// MODAL CONTROLS & UTILITIES
// ==============================================
function openModal(id) {
  const m = document.getElementById(id);
  if (m) m.classList.add('active');
}

function closeModal(id) {
  const m = document.getElementById(id);
  if (m) m.classList.remove('active');
}

function showToast(message, type = 'info') {
  const container = document.getElementById('toastContainer');
  if (!container) return;

  const toast = document.createElement('div');
  toast.className = `toast toast-${type}`;
  toast.innerHTML = `<span>${escapeHtml(message)}</span>`;
  container.appendChild(toast);

  setTimeout(() => {
    toast.style.opacity = '0';
    toast.style.transform = 'translateX(100%)';
    toast.style.transition = 'all 0.3s ease';
    setTimeout(() => toast.remove(), 300);
  }, 3500);
}

function calculateTimeRemaining(dateStr) {
  const due = new Date(dateStr);
  const now = new Date();
  const diffMs = due - now;

  if (diffMs <= 0) {
    return { isPast: true, text: 'เลยกำหนดส่งแล้ว', colorClass: 'ticker-red', icon: '⚠️' };
  }

  const days = Math.floor(diffMs / (1000 * 60 * 60 * 24));
  const hours = Math.floor((diffMs / (1000 * 60 * 60)) % 24);

  if (days > 2) {
    return { isPast: false, text: `เหลือเวลาอีก ${days} วัน`, colorClass: 'ticker-green', icon: '⏱️' };
  } else if (days >= 1) {
    return { isPast: false, text: `เหลือเวลา ${days} วัน ${hours} ชม.`, colorClass: 'ticker-amber', icon: '⏰' };
  } else {
    return { isPast: false, text: `ใกล้หมดเวลา (เหลือ ${hours} ชม.)`, colorClass: 'ticker-red', icon: '🔥' };
  }
}

function formatThaiDateTime(dateStr) {
  if (!dateStr) return '-';
  const d = new Date(dateStr);
  if (isNaN(d.getTime())) return dateStr;
  
  const thMonths = ['ม.ค.', 'ก.พ.', 'มี.ค.', 'เม.ย.', 'พ.ค.', 'มิ.ย.', 'ก.ค.', 'ส.ค.', 'ก.ย.', 'ต.ค.', 'พ.ย.', 'ธ.ค.'];
  const day = d.getDate();
  const month = thMonths[d.getMonth()];
  const year = (d.getFullYear() + 543).toString().slice(-2);
  const hours = d.getHours().toString().padStart(2, '0');
  const minutes = d.getMinutes().toString().padStart(2, '0');

  return `${day} ${month} ${year} (${hours}:${minutes} น.)`;
}

function formatTimeOnly(dateStr) {
  if (!dateStr) return '-';
  const d = new Date(dateStr);
  if (isNaN(d.getTime())) return dateStr;
  const thMonths = ['ม.ค.', 'ก.พ.', 'มี.ค.', 'เม.ย.', 'พ.ค.', 'มิ.ย.', 'ก.ค.', 'ส.ค.', 'ก.ย.', 'ต.ค.', 'พ.ย.', 'ธ.ค.'];
  return `${d.getDate()} ${thMonths[d.getMonth()]} ${d.getHours().toString().padStart(2, '0')}:${d.getMinutes().toString().padStart(2, '0')}`;
}

function formatBytes(bytes) {
  if (bytes === 0) return '0 B';
  const k = 1024;
  const sizes = ['B', 'KB', 'MB', 'GB'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return parseFloat((bytes / Math.pow(k, i)).toFixed(1)) + ' ' + sizes[i];
}

function getAvatarInitials(name) {
  if (!name) return 'ST';
  const clean = name.replace(/นาย|นางสาว|เด็กชาย|เด็กหญิง/g, '').trim();
  return clean.slice(0, 2);
}

function escapeHtml(str) {
  if (!str) return '';
  return str.toString()
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}
