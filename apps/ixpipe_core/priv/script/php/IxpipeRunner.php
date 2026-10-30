<?php
declare(strict_types=1);

/**
 * Runs a Script tool's PHP code: unsandboxed, in the user's PHP.
 *
 * `$inputs` maps each input to rows (arrays) or, with the parquet format, to
 * its Parquet file. The script sets `$output`: a list of rows or an array of
 * columns.
 */
final class IxpipeRunner
{
    private const MAX_TEXT = 1000000;

    public static function run(string $code, iterable $inputs, string $output_path, string $format): array
    {
        $result = ['stdout' => '', 'stderr' => '', 'error' => null, 'written' => null];
        $missing = new stdClass();
        ob_start();
        try {
            $data = [];
            foreach ($inputs as $name => $path) {
                $data[$name] = $format === 'parquet' ? $path : self::read($path);
            }
            $result['written'] = self::write(self::evaluate($code, $data, $output_path, $missing), $output_path, $format, $missing);
        } catch (\Throwable $e) {
            $result['error'] = self::failure($e);
        } finally {
            $result['stdout'] = substr((string) ob_get_clean(), 0, self::MAX_TEXT);
        }
        return $result;
    }

    private static function evaluate(string $__code, array $inputs, string $output_path, object $__missing): mixed
    {
        $output = $__missing;
        eval($__code);
        return $output;
    }

    private static function read(string $path): array
    {
        $rows = [];
        foreach (file($path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
            $rows[] = json_decode($line, true, 512, JSON_THROW_ON_ERROR);
        }
        return $rows;
    }

    private static function write(mixed $output, string $path, string $format, object $missing): array
    {
        if ($output === $missing) {
            return $format === 'parquet' && file_exists($path) ? ['format' => 'parquet'] : ['missing' => true];
        }
        if (!is_array($output)) {
            return ['bad' => 'output is a ' . get_debug_type($output)];
        }
        if (array_is_list($output)) {
            foreach ($output as $row) {
                if (!is_array($row) || ($row !== [] && array_is_list($row))) {
                    return ['bad' => 'output is a list of ' . get_debug_type($row) . ', not of rows'];
                }
            }
            $rows = $output;
            $columns = array_values(array_unique(array_merge([], ...array_map('array_keys', $rows))));
        } else {
            $columns = array_map('strval', array_keys($output));
            $values = array_map('array_values', array_values($output));
            if (count(array_unique(array_map('count', $values))) > 1) {
                return ['bad' => "output's columns have different lengths"];
            }
            $rows = [];
            foreach (array_keys($values[0] ?? []) as $i) {
                $rows[] = array_combine($columns, array_column($values, $i));
            }
        }
        $f = fopen($path, 'w');
        foreach ($rows as $row) {
            fwrite($f, json_encode($row, JSON_THROW_ON_ERROR) . "\n");
        }
        fclose($f);
        return ['format' => 'jsonl', 'columns' => array_map('strval', $columns), 'rows' => count($rows)];
    }

    private static function failure(\Throwable $e): array
    {
        $line = null;
        if (str_contains($e->getFile(), "eval()'d code")) {
            $line = $e->getLine();
        } else {
            foreach ($e->getTrace() as $frame) {
                if (str_contains($frame['file'] ?? '', "eval()'d code")) {
                    $line = $frame['line'];
                    break;
                }
            }
        }
        $trace = get_class($e) . ': ' . $e->getMessage() . "\n" . $e->getTraceAsString();
        return [
            'type' => get_class($e),
            'message' => $e->getMessage(),
            'line' => $line,
            'traceback' => substr($trace, 0, self::MAX_TEXT),
        ];
    }
}
