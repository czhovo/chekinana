const WEEKDAYS = ["日", "一", "二", "三", "四", "五", "六"];
const MIN_PICKER_MONTH = "1970-01";
const MAX_PICKER_MONTH = "2099-12";
const SWIPE_THRESHOLD = 60;

function padNumber(value) {
  return value < 10 ? `0${value}` : `${value}`;
}

function getDateKey(year, month, day) {
  return `${year}-${padNumber(month + 1)}-${padNumber(day)}`;
}

function getPickerValue(year, month) {
  return `${year}-${padNumber(month + 1)}`;
}

function getDisplayDateText(year, month, day) {
  return `${year}年${month + 1}月${day}日`;
}

function getDaysInMonth(year, month) {
  return new Date(year, month + 1, 0).getDate();
}

function createDateCell(year, month, day, isCurrentMonth, selectedDateKey) {
  const dateKey = getDateKey(year, month, day);

  return {
    year,
    month,
    day,
    dateKey,
    isCurrentMonth,
    isSelected: dateKey === selectedDateKey
  };
}

function createCalendarWeeks(year, month, selectedDateKey) {
  const firstWeekday = new Date(year, month, 1).getDay();
  const daysInCurrentMonth = getDaysInMonth(year, month);
  const visibleRows = Math.ceil((firstWeekday + daysInCurrentMonth) / 7);
  const visibleCellCount = visibleRows * 7;
  const weeks = [];
  const cells = [];
  const previousMonth = month - 1;
  const previousMonthYear = previousMonth < 0 ? year - 1 : year;
  const previousMonthIndex = previousMonth < 0 ? 11 : previousMonth;
  const previousMonthDays = getDaysInMonth(previousMonthYear, previousMonthIndex);

  for (let index = 0; index < visibleCellCount; index += 1) {
    const cellDay = index - firstWeekday + 1;

    if (cellDay < 1) {
      const day = previousMonthDays + cellDay;
      cells.push(createDateCell(previousMonthYear, previousMonthIndex, day, false, selectedDateKey));
    } else if (cellDay > daysInCurrentMonth) {
      const nextMonth = month + 1;
      const nextMonthYear = nextMonth > 11 ? year + 1 : year;
      const nextMonthIndex = nextMonth > 11 ? 0 : nextMonth;
      const day = cellDay - daysInCurrentMonth;
      cells.push(createDateCell(nextMonthYear, nextMonthIndex, day, false, selectedDateKey));
    } else {
      cells.push(createDateCell(year, month, cellDay, true, selectedDateKey));
    }
  }

  for (let rowIndex = 0; rowIndex < visibleRows; rowIndex += 1) {
    weeks.push(cells.slice(rowIndex * 7, rowIndex * 7 + 7));
  }

  return weeks;
}

function createCalendarState(displayYear, displayMonth, selectedYear, selectedMonth, selectedDay) {
  const selectedDateKey = getDateKey(selectedYear, selectedMonth, selectedDay);

  return {
    displayYear,
    displayMonth,
    selectedYear,
    selectedMonth,
    selectedDay,
    selectedDateKey,
    selectedDateText: getDisplayDateText(selectedYear, selectedMonth, selectedDay),
    pickerValue: getPickerValue(displayYear, displayMonth),
    monthTitle: `${displayYear}年${displayMonth + 1}月`,
    weeks: createCalendarWeeks(displayYear, displayMonth, selectedDateKey)
  };
}

Page({
  data: {
    weekdays: WEEKDAYS,
    minPickerMonth: MIN_PICKER_MONTH,
    maxPickerMonth: MAX_PICKER_MONTH,
    pickerValue: "",
    monthTitle: "",
    displayYear: 0,
    displayMonth: 0,
    selectedYear: 0,
    selectedMonth: 0,
    selectedDay: 0,
    selectedDateKey: "",
    selectedDateText: "",
    weeks: []
  },

  touchStartX: 0,
  touchStartY: 0,

  onLoad() {
    const today = new Date();
    this.setData(createCalendarState(
      today.getFullYear(),
      today.getMonth(),
      today.getFullYear(),
      today.getMonth(),
      today.getDate()
    ));
  },

  showPreviousMonth() {
    this.changeMonth(-1);
  },

  showNextMonth() {
    this.changeMonth(1);
  },

  changeMonth(offset) {
    const nextDate = new Date(this.data.displayYear, this.data.displayMonth + offset, 1);
    this.setData(createCalendarState(
      nextDate.getFullYear(),
      nextDate.getMonth(),
      this.data.selectedYear,
      this.data.selectedMonth,
      this.data.selectedDay
    ));
  },

  onMonthPickerChange(event) {
    const value = event.detail.value;
    const parts = value.split("-");
    const year = Number(parts[0]);
    const month = Number(parts[1]) - 1;

    if (!Number.isFinite(year) || !Number.isFinite(month)) return;

    this.setData(createCalendarState(
      year,
      month,
      this.data.selectedYear,
      this.data.selectedMonth,
      this.data.selectedDay
    ));
  },

  onDateTap(event) {
    const year = Number(event.currentTarget.dataset.year);
    const month = Number(event.currentTarget.dataset.month);
    const day = Number(event.currentTarget.dataset.day);

    if (!Number.isFinite(year) || !Number.isFinite(month) || !Number.isFinite(day)) return;

    this.setData(createCalendarState(
      this.data.displayYear,
      this.data.displayMonth,
      year,
      month,
      day
    ));
  },

  onCalendarTouchStart(event) {
    const touch = event.changedTouches[0];
    this.touchStartX = touch.clientX;
    this.touchStartY = touch.clientY;
  },

  onCalendarTouchEnd(event) {
    const touch = event.changedTouches[0];
    const deltaX = touch.clientX - this.touchStartX;
    const deltaY = touch.clientY - this.touchStartY;

    if (Math.abs(deltaX) < SWIPE_THRESHOLD || Math.abs(deltaX) <= Math.abs(deltaY)) return;

    if (deltaX < 0) {
      this.showNextMonth();
    } else {
      this.showPreviousMonth();
    }
  }
});
