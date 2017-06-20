defmodule AlloyCi.Pipelines do
  @moduledoc """
  The boundary for the Pipelines system.
  """
  import Ecto.Query, warn: false
  alias AlloyCi.{Builds, ExqEnqueuer, Pipeline, Projects, Repo, Workers.CreateBuildsWorker}

  @github_api Application.get_env(:alloy_ci, :github_api)

  def cancel(pipeline) do
    with {:ok, _} <- update_pipeline(pipeline, %{status: "cancelled"}) do
      case Builds.cancel(pipeline) do
        {_, nil} -> {:ok, nil}
        {_, _}   -> :error
      end
    end
  end

  def create_pipeline(pipeline, params) do
    pipeline
    |> Pipeline.changeset(params)
    |> Repo.insert
  end

  def duplicate(pipeline) do
    with {:ok, _} <- update_pipeline(pipeline, %{sha: pipeline.sha |> String.slice(0..7)}) do
      case clone(pipeline) do
        {:ok, clone} ->
          ExqEnqueuer.push(CreateBuildsWorker, [clone.id])
          {:ok, clone}
      end
    end
  end

  def failed!(pipeline) do
    pipeline = pipeline |> Repo.preload(:project)
    @github_api.notify_failure!(pipeline.project, pipeline)
    finished_at = Timex.now
    duration = Timex.diff(finished_at, Timex.to_datetime(pipeline.started_at, :utc), :seconds)
    {:ok, _} = update_pipeline(pipeline, %{status: "failed", duration: duration, finished_at: finished_at})
    # Notify user that pipeline failed. (Email and badge)
  end

  def for_project(project_id) do
    Pipeline
    |> where(project_id: ^project_id)
    |> where([p], p.status == "pending" or p.status == "running")
    |> order_by(asc: :inserted_at)
    |> Repo.all
  end

  def get(id) do
    Pipeline
    |> Repo.get_by(id: id)
  end

  def get_pipeline(id, project_id, user) do
    with true <- Projects.can_access?(project_id, user) do
      Pipeline
      |> where(project_id: ^project_id)
      |> Repo.get(id)
      |> Repo.preload(:project)
    end
  end

  def get_with_project(id) do
    Pipeline
    |> Repo.get_by(id: id)
    |> Repo.preload(:project)
  end

  def paginated(project_id, params) do
    Pipeline
    |> where(project_id: ^project_id)
    |> order_by(desc: :inserted_at)
    |> Repo.paginate(params)
  end

  def run!(pipeline) do
    if pipeline.status == "pending" do
      update_pipeline(pipeline, %{status: "running", started_at: Timex.now})
    end
  end

  def success!(pipeline_id) do
    pipeline =
      pipeline_id
      |> get
      |> Repo.preload([:builds, :project])

    query = from b in "builds",
            where: b.pipeline_id == ^pipeline.id and b.status == "success",
            select: count(b.id)
    successful_builds = Repo.one(query)

    query = from b in "builds",
            where: b.pipeline_id == ^pipeline.id and b.status == "failed" and b.allow_failure == true,
            select: count(b.id)
    allowed_failures = Repo.one(query)

    if (successful_builds + allowed_failures) == Enum.count(pipeline.builds) do
      @github_api.notify_success!(pipeline.project, pipeline)
      finished_at = Timex.now
      duration = Timex.diff(finished_at, Timex.to_datetime(pipeline.started_at, :utc), :seconds)
      update_pipeline(pipeline, %{status: "success", duration: duration, finished_at: finished_at})
      # Notify user of successfull pipeline, email.
    end
  end

  def update_pipeline(%Pipeline{} = pipeline, params) do
    pipeline
    |> Pipeline.changeset(params)
    |> Repo.update
  end

  def update_status(pipeline_id) do
    pipeline = get(pipeline_id)

    query = from b in "builds",
            where: b.pipeline_id == ^pipeline_id and b.status in ~w(pending running success failed skipped),
            order_by: [desc: b.id], limit: 1,
            select: %{status: b.status, allow_failure: b.allow_failure}
    last_status = Repo.one(query) || %{status: "skipped", allow_failure: false}

    case last_status do
      %{status: "success"} -> success!(pipeline_id)
      %{status: "failed", allow_failure: false} -> failed!(pipeline)
      %{status: "skipped"} -> update_pipeline(pipeline, %{status: "running"})
      %{status: "running"} -> update_pipeline(pipeline, %{status: "running"})
      _ -> nil
    end
  end

  ##################
  # Private funtions
  ##################
  defp clone(pipeline) do
    pipeline
    |> Map.drop([:id, :inserted_at, :updated_at, :builds, :project, :status])
    |> Map.merge(%{builds: []})
    |> Repo.insert
  end
end
