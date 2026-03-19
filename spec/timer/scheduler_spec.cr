# spec/timer/scheduler_spec.cr

require "spec"
require "../../src/timer/scheduler"

module Litin::Timer
  describe CalendarExpr do
    describe ".next_after" do
      it "handles 'hourly'" do
        from = Time.utc(2025, 6, 1, 14, 30, 0)
        t = CalendarExpr.next_after("hourly", from).not_nil!
        t.hour.should eq(15)
        t.minute.should eq(0)
        t.second.should eq(0)
      end

      it "handles 'daily'" do
        from = Time.utc(2025, 6, 1, 14, 30, 0)
        t = CalendarExpr.next_after("daily", from).not_nil!
        t.should eq(Time.utc(2025, 6, 2, 0, 0, 0))
      end

      it "handles 'weekly'" do
        # 2025-06-01 is a Sunday (dow=0). Next Monday is 2025-06-02.
        from = Time.utc(2025, 6, 1, 0, 0, 0)
        t = CalendarExpr.next_after("weekly", from).not_nil!
        t.day_of_week.should eq(Time::DayOfWeek::Monday)
        t > from
      end

      it "handles 'monthly'" do
        from = Time.utc(2025, 6, 15, 10, 0, 0)
        t = CalendarExpr.next_after("monthly", from).not_nil!
        t.should eq(Time.utc(2025, 7, 1, 0, 0, 0))
      end

      it "handles HH:MM later in the same day" do
        from = Time.utc(2025, 6, 1, 10, 0, 0)
        t = CalendarExpr.next_after("23:00", from).not_nil!
        t.should eq(Time.utc(2025, 6, 1, 23, 0, 0))
      end

      it "handles HH:MM rolling to next day" do
        from = Time.utc(2025, 6, 1, 23, 30, 0)
        t = CalendarExpr.next_after("02:00", from).not_nil!
        t.should eq(Time.utc(2025, 6, 2, 2, 0, 0))
      end

      it "handles cron '*/5 * * * *'" do
        from = Time.utc(2025, 6, 1, 14, 3, 0)
        t = CalendarExpr.next_after("*/5 * * * *", from).not_nil!
        t.minute.should eq(5)
        t.hour.should eq(14)
      end

      it "handles cron '0 9 * * 1'" do
        # Every Monday at 09:00.
        from = Time.utc(2025, 6, 3, 10, 0, 0) # Tuesday
        t = CalendarExpr.next_after("0 9 * * 1", from).not_nil!
        t.day_of_week.should eq(Time::DayOfWeek::Monday)
        t.hour.should eq(9)
        t.minute.should eq(0)
      end
    end
  end

  describe TimerParser do
    describe ".parse_duration" do
      it "parses plain seconds" do
        TimerParser.parse_duration("30").should eq(30)
      end

      it "parses minutes" do
        TimerParser.parse_duration("5min").should eq(300)
      end

      it "parses hours" do
        TimerParser.parse_duration("2h").should eq(7200)
      end

      it "parses days" do
        TimerParser.parse_duration("1day").should eq(86400)
      end

      it "returns nil for garbage" do
        TimerParser.parse_duration("notatime").should be_nil
      end
    end
  end
end
