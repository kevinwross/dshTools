/**
 * Host plugin: the `local-datetime` tool.
 *
 * Answers "what time is it here?" for the machine that runs the Agent. All
 * formatting goes through the host's own `Intl` defaults, so the strings match
 * the date/time conventions of the locale and time zone the host is set to.
 *
 * Dependency-free plain ESM: the definition is a raw ToolDefinition, so the
 * bundle needs no `@deepseek-ai/*` imports and no build step.
 */

/** Cordis plugin name used by loader diagnostics. */
export const name = 'local-datetime'

/** Register only once the global tool registry exists. */
export const inject = ['tools']

const description = 'Read the current local date and time on the machine that hosts the agent. '
  + 'Use it whenever the answer depends on "now": today\'s date, the current time, the weekday, '
  + 'the host\'s time zone, or how long ago something happened. Strings use the host\'s own locale '
  + 'and time zone. The instant comes back as `datetime`, as separate `date` and `time` strings, '
  + 'and as the numeric parts `year`, `month`, `day`, `hour` (0-23, 24-hour), `minute`, and '
  + '`second`; `timeZone`, `utcOffset`, `locale`, and `iso` state the exact frame.'

/** Left-pad a non-negative integer to two digits. */
function pad2(value) {
  return String(value).padStart(2, '0')
}

/** Render a signed minute offset as `±HH:MM`. */
function offsetText(offsetMinutes) {
  const sign = offsetMinutes < 0 ? '-' : '+'
  const absolute = Math.abs(offsetMinutes)
  return `${sign}${pad2(Math.floor(absolute / 60))}:${pad2(absolute % 60)}`
}

/** Sample the host clock and localize it with the host's own defaults. */
function localDateTime() {
  const now = new Date()
  const resolved = new Intl.DateTimeFormat().resolvedOptions()
  const utcOffset = offsetText(-now.getTimezoneOffset())
  return {
    datetime: now.toLocaleString(),
    date: now.toLocaleDateString(),
    time: now.toLocaleTimeString(),
    year: now.getFullYear(),
    month: now.getMonth() + 1,
    day: now.getDate(),
    hour: now.getHours(),
    minute: now.getMinutes(),
    second: now.getSeconds(),
    timeZone: resolved.timeZone,
    utcOffset,
    locale: resolved.locale,
    iso: `${now.getFullYear()}-${pad2(now.getMonth() + 1)}-${pad2(now.getDate())}`
      + `T${pad2(now.getHours())}:${pad2(now.getMinutes())}:${pad2(now.getSeconds())}${utcOffset}`,
  }
}

/** Raw registry definition: no parameters, one localized JSON object out. */
const definition = {
  name: 'local-datetime',
  description,
  parameters: { type: 'object', properties: {}, additionalProperties: false },
  output: {
    schema: {
      type: 'object',
      additionalProperties: false,
      required: [
        'datetime', 'date', 'time',
        'year', 'month', 'day', 'hour', 'minute', 'second',
        'timeZone', 'utcOffset', 'locale', 'iso',
      ],
      properties: {
        datetime: {
          type: 'string',
          description: 'The localized date and time on the host, e.g. "11/5/2025, 2:32:07 PM".',
        },
        date: {
          type: 'string',
          description: 'The localized date alone, e.g. "11/5/2025".',
        },
        time: {
          type: 'string',
          description: 'The localized time alone, e.g. "2:32:07 PM".',
        },
        year: {
          type: 'integer',
          description: 'Four-digit local year, e.g. 2026.',
        },
        month: {
          type: 'integer',
          description: 'Local month of the year, 1-12.',
        },
        day: {
          type: 'integer',
          description: 'Local day of the month, 1-31.',
        },
        hour: {
          type: 'integer',
          description: 'Local hour on a 24-hour clock, 0-23.',
        },
        minute: {
          type: 'integer',
          description: 'Local minute, 0-59.',
        },
        second: {
          type: 'integer',
          description: 'Local second, 0-59.',
        },
        timeZone: {
          type: 'string',
          description: 'The host IANA time zone, e.g. "America/New_York".',
        },
        utcOffset: {
          type: 'string',
          description: 'The host UTC offset as ±HH:MM, e.g. "-05:00".',
        },
        locale: {
          type: 'string',
          description: 'The locale the strings were formatted in, e.g. "en-US".',
        },
        iso: {
          type: 'string',
          description: 'The same instant as local ISO 8601 with offset, e.g. "2025-11-05T14:32:07-05:00".',
        },
      },
    },
    render: (_args, value) => [{ type: 'text', text: JSON.stringify(value, null, 2) }],
  },
  isConcurrencySafe: () => true,
  execute() {
    return Promise.resolve(localDateTime())
  },
}

/**
 * Register the tool for the lifetime of this plugin row.
 * @param ctx - host context; the registration is removed when the row unloads.
 */
export function apply(ctx) {
  ctx.effect(() => ctx.tools.register(definition), 'local-datetime tool')
}
