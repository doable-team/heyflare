import { useRef, useState } from "react";
import { Images, Loader2 } from "lucide-react";
import type { CalendarDay } from "@shared/types";
import { cn } from "@/lib/utils";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { useCalendarDayMutation, useDayCoverMutations } from "../api";

/**
 * A day's photo — the feature Jason Fried says came from taping pictures to a paper wall calendar:
 * "Paper calendars though, you can put stickers… or stick little photos. That's where the idea came
 * from, to be able to add photos to cells."
 *
 * The photo is drawn at **full strength**: no scrim, no dim, no blur. HEY handles readability
 * inside the content instead — event blocks stay fully opaque and gain a white keyline over a
 * photo, and the day's number flips to white. A veil over the picture would be the obvious move and
 * is measurably not what they do; it also makes the photo pointless.
 */
export function DayPhotoBackdrop({ day, className }: { day: CalendarDay | undefined; className?: string }) {
  if (!day?.cover_url) return null;
  return (
    <img
      src={day.cover_url}
      alt=""
      loading="lazy"
      aria-hidden
      className={cn("pointer-events-none absolute inset-0 h-full w-full object-cover", className)}
      style={{ objectPosition: day.cover_position || "50% 50%" }}
    />
  );
}

/** True when a day is carrying a photo, so callers can switch to their over-photo treatment. */
export function hasPhoto(day: CalendarDay | undefined): boolean {
  return !!day?.cover_url;
}

/**
 * The picker. HEY's has exactly two affordances — upload, and remove once there is one — reached
 * from a photo icon in the day's top-left corner. No library, no stock search, no crop step.
 */
export function DayPhotoButton({ date, day, className }: { date: string; day: CalendarDay | undefined; className?: string }) {
  const [open, setOpen] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const fileRef = useRef<HTMLInputElement>(null);
  const { upload } = useDayCoverMutations();
  const setDay = useCalendarDayMutation();
  const has = hasPhoto(day);
  const busy = upload.isPending || setDay.isPending;

  const pick = async (file: File | undefined) => {
    if (!file) return;
    setError(null);
    try {
      const cover = await upload.mutateAsync(file);
      await setDay.mutateAsync({ date, cover_id: cover.id });
      setOpen(false);
    } catch (e) {
      setError((e as Error).message || "That didn't upload.");
    }
  };

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <button
          type="button"
          aria-label={has ? "Change this day's photo" : "Give this day a background"}
          className={cn(
            "rounded-[5px] bg-background/85 p-1 text-foreground/70 shadow-[0_1px_3px_rgba(0,0,0,0.18)] backdrop-blur-[2px]",
            "transition-colors hover:bg-background hover:text-foreground",
            className,
          )}
        >
          <Images size={13} />
        </button>
      </PopoverTrigger>
      <PopoverContent align="start" className="w-64 p-4">
        <input
          ref={fileRef}
          type="file"
          accept="image/*"
          hidden
          onChange={(e) => {
            void pick(e.target.files?.[0]);
            e.target.value = "";
          }}
        />
        <h3 className="text-[11px] font-semibold uppercase tracking-[0.07em] text-muted-foreground">Give this day a background</h3>
        <button
          type="button"
          onClick={() => fileRef.current?.click()}
          disabled={busy}
          className="mt-3 inline-flex h-9 w-full items-center justify-center gap-1.5 rounded-full border-2 border-foreground text-[13px] font-semibold transition-colors hover:bg-foreground hover:text-background disabled:opacity-60"
        >
          {busy && <Loader2 size={13} className="animate-spin" />}
          {busy ? "Uploading…" : has ? "Upload a different image" : "Upload an image"}
        </button>
        {has && (
          <button
            type="button"
            onClick={() => {
              setDay.mutate({ date, cover_id: null, cover_url: "" });
              setOpen(false);
            }}
            className="mx-auto mt-3 block text-[12px] text-muted-foreground underline underline-offset-2 hover:text-foreground"
          >
            Remove background
          </button>
        )}
        {error && <p className="mt-3 text-[11.5px] text-muted-foreground">{error}</p>}
      </PopoverContent>
    </Popover>
  );
}
