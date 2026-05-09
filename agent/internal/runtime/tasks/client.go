package tasks

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
)

// Client is the typed wrapper around the platform's /status/tasks/*
// endpoints. Each method handles request encoding, response decoding,
// and error wrapping so the loop stays focused on orchestration.
type Client struct {
	HTTP HTTPClient
}

// NewClient returns a typed client wrapping the given HTTPClient
// (typically *transport.SwappableClient).
func NewClient(h HTTPClient) *Client {
	return &Client{HTTP: h}
}

// ListPending returns all tasks currently in pending/acknowledged/
// running state for this instance.
func (c *Client) ListPending() ([]Task, error) {
	if c == nil || c.HTTP == nil {
		return nil, errors.New("tasks.Client: nil HTTP")
	}
	resp, err := c.HTTP.GetJSON("/api/v1/system/node_api/status/tasks")
	if err != nil {
		return nil, fmt.Errorf("get pending tasks: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("status/tasks status %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var env struct {
		Success bool `json:"success"`
		Data    struct {
			Tasks []Task `json:"tasks"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, fmt.Errorf("decode tasks: %w", err)
	}
	return env.Data.Tasks, nil
}

// Get fetches a single task by id. Returns the task and a "found" flag
// (false on 404 — used by the crash-recovery path to detect tasks
// that the platform has already moved to a terminal state while the
// agent was down).
func (c *Client) Get(id string) (*Task, bool, error) {
	if id == "" {
		return nil, false, errors.New("tasks.Get: empty id")
	}
	resp, err := c.HTTP.GetJSON("/api/v1/system/node_api/status/tasks/" + id)
	if err != nil {
		return nil, false, fmt.Errorf("get task %s: %w", id, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == 404 {
		return nil, false, nil
	}
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, false, fmt.Errorf("get task %s status %d: %s", id, resp.StatusCode, strings.TrimSpace(string(body)))
	}
	var env struct {
		Success bool `json:"success"`
		Data    struct {
			Task Task `json:"task"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, false, fmt.Errorf("decode: %w", err)
	}
	return &env.Data.Task, true, nil
}

// Acknowledge transitions the task from pending → acknowledged
// server-side. The agent should call this BEFORE invoking the
// handler so the platform's reaper knows the agent owns the task
// even if the handler crashes mid-execution.
func (c *Client) Acknowledge(id string) error {
	return c.postNoBody("/api/v1/system/node_api/status/tasks/" + id + "/acknowledge")
}

// Complete reports the handler's Result and transitions the task
// to complete server-side.
func (c *Client) Complete(id string, result Result) error {
	body, err := json.Marshal(map[string]any{"result": result})
	if err != nil {
		return fmt.Errorf("marshal result: %w", err)
	}
	resp, err := c.HTTP.PostJSON("/api/v1/system/node_api/status/tasks/"+id+"/complete", body)
	if err != nil {
		return fmt.Errorf("complete %s: %w", id, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("complete %s status %d: %s", id, resp.StatusCode, strings.TrimSpace(string(respBody)))
	}
	return nil
}

// Fail reports a handler error to the platform. The platform
// transitions the task to failed and surfaces the message in the
// operator UI.
func (c *Client) Fail(id, message string) error {
	body, err := json.Marshal(map[string]any{"error": message})
	if err != nil {
		return err
	}
	resp, err := c.HTTP.PostJSON("/api/v1/system/node_api/status/tasks/"+id+"/fail", body)
	if err != nil {
		return fmt.Errorf("fail %s: %w", id, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("fail %s status %d: %s", id, resp.StatusCode, strings.TrimSpace(string(respBody)))
	}
	return nil
}

// postNoBody is a small helper for endpoints that don't require a
// body (acknowledge).
func (c *Client) postNoBody(path string) error {
	resp, err := c.HTTP.PostJSON(path, []byte("{}"))
	if err != nil {
		return fmt.Errorf("post %s: %w", path, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("post %s status %d: %s", path, resp.StatusCode, strings.TrimSpace(string(body)))
	}
	return nil
}
