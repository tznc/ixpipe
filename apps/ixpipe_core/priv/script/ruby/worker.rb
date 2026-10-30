# frozen_string_literal: true

# The Script tool's Ruby worker: portals starts it with the socket path last.
require 'portals'
require_relative 'ixpipe_runner'

Portals::Worker.new(max_concurrency: 1, modules: { 'ixpipe_runner' => IxpipeRunner }).run
